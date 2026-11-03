# Fork plan: database-driven `/data` configuration with hot reload

Status: **DRAFT, waiting on the open questions in §9**
Base: upstream `overextended/ox_inventory` v2.48.1 (`39d4cc7`)

---

## 1. Goals

1. Every config file in `data/` is backed by its own database table, plus child tables where the
   shape is nested.
2. Config can be changed while the server runs. An update command (and an export) re-reads the
   DB, checks it, and applies it on the server and on every connected client, with no restart.
3. **Keep the fork easy to rebase on upstream releases.** This rule wins whenever it conflicts
   with the other goals.

Out of scope unless §9 says otherwise: convars in `init.lua` (`inventory:*`), locales, and the web UI
beyond the smallest patch needed.

---

## 2. What upstream does today

Upstream reads each data file with `lib.load('data.<name>')` once, when the module loads. No
module can reload its data. The client reads the **same Lua files** itself (`fxmanifest.lua`
ships `data/*.lua` in `files {}`), so today a client never gets config from the server.

| Data file | Read in (server) | Read in (client) | What it builds |
|---|---|---|---|
| `items.lua` | `modules/items/shared.lua:109`, `modules/bridge/esx/server.lua:12` | `modules/items/shared.lua:109` | `ItemList`; ESX status sync |
| `weapons.lua` (`Weapons`/`Components`/`Ammo`, plus `Tints` support in code) | `modules/items/shared.lua:76` | same | weapon, component and ammo items in `ItemList` |
| `shops.lua` | `modules/shops/server.lua:111` | `modules/shops/client.lua:7` | `Shops`, shop points or targets, peds, blips |
| `stashes.lua` | `modules/inventory/server.lua:83` | `modules/inventory/client.lua:360` | `RegisteredStashes`; zones/points |
| `crafting.lua` | `modules/crafting/server.lua:46` | `modules/crafting/client.lua:96` | `CraftingBenches`; zones/points/blips |
| `evidence.lua` | none | `modules/inventory/client.lua:321` | evidence zones/points |
| `licenses.lua` | `server.lua:361` | `client.lua:1325` | license purchase points |
| `vehicles.lua` | `modules/inventory/server.lua:80` | `client.lua:123`, `modules/inventory/client.lua:51` | trunk/glovebox capacity, storage flags |
| `animations.lua` | none | `client.lua:357` | anim/prop lookup for item use |

Other things that matter:

- `data/items.lua` can contain **Lua functions** (`buttons[].action`), and other files evaluate
  expressions when loaded: `` `hash` `` literals, `vec3(...)`, `shared.police`. None of these can
  be stored in a DB as they are.
- `modules/items/server.lua:77-107` (ESX/QB item import) **writes back to `data/items.lua`**.
- The NUI receives item data once, in the `init` message (`client.lua:1341`). After that it only
  fetches items it doesn't know yet (`web/src/helpers/index.ts:135`). Item changes made while
  the server runs will not show in the UI without a new NUI message.
- Exports such as `RegisterShop` and `Items` must keep their current behavior.

---

## 3. Upstream compatibility strategy

1. **Leave `data/*.lua` untouched.** These files are the *base layer*. When upstream adds weapons
   to `weapons.lua` (it does this often), they arrive with no conflict and no migration work.
2. **Put fork code in new paths only:** `modules/dbconfig/**`, `sql/dbconfig/**`, `.fork/**`.
   Upstream never touches these paths.
3. **Keep upstream edits small and marked.** Each touch point changes as few lines as possible
   and carries a `-- [fork:dbconfig]` comment, so a rebase conflict is quick to spot and fix.
   Planned touch points:
   - `fxmanifest.lua`: add `modules/dbconfig/*.lua` to `files`. One line.
   - Each `lib.load('data.X')` call site in the table above (about 14 lines) becomes
     `require 'modules.dbconfig'.get('X')`.
   - Teardown/apply hooks for hot reload (§6). Where upstream already has a re-run function
     (`Inventory.Stashes()` and `Inventory.Evidence()` are callable metatables), the fork reuses
     it. Where upstream has none (shops, crafting, licenses), the loop body moves into a local
     function that the fork can call again. **These are the riskiest hunks for rebases.** It is
     worth offering the refactors upstream as PRs, since "allow re-registering shops/benches"
     is generally useful.
4. **Add a kill switch.** The convar `inventory:dbconfig 0` makes `get()` fall back to plain
   `lib.load`, which gives exact upstream behavior. This helps when bisecting an upstream bug.
5. **Rebase checklist** (`.fork/REBASE.md`): run `git grep -n "lib.load('data\."` after every
   upstream merge. Any new hit is an unpatched call site, and CI can fail the build on it.

---

## 4. How the layers merge

```
effective config = data/<file>.lua (upstream base)
                 ⊕ DB rows (override or add, per entity key)
                 − DB rows with enabled = 0 (tombstone: hides a base entry)
```

- Entity keys: item name, weapon name, shop type, stash name, bench name, license name,
  vehicle model or class, anim/prop name.
- A DB row replaces the matching base entity whole. Fields are not merged one by one, because
  field-level merging is hard to reason about.
- Every parent table has an `extra JSON` column. Any key that has no dedicated column
  round-trips through it. When upstream adds a new item field, it works at once without a
  schema change.
- Functions (item `buttons[].action`, etc.) live **only** in the Lua base layer. The DB can
  reference them (see Q1).

---

## 5. Schema (draft)

All tables use the prefix `ox_inv_cfg_`. InnoDB, utf8mb4. Child tables cascade on delete. Every
row has `updated_at`. Coordinates are stored as `x, y, z DOUBLE`. Model and component hashes are
stored as **names** (`joaat()` runs at load time), with a numeric fallback.

**Meta**
- `ox_inv_cfg_meta (config PK, revision INT, updated_at, updated_by)`: one row per config,
  bumped on every change. The reload command and the clients use it to detect changes.
- `ox_inv_cfg_migrations (version PK, applied_at)`

**items**
- `items (name PK, enabled, label, weight, stack, close, description, degrade, decay, consume,
  durability, extra JSON)`
- `item_client (item FK PK, image, anim_ref, prop_ref, usetime, export, cancel, notification,
  status JSON, disable JSON, extra JSON)`. `anim` and `prop` are either a reference to
  `animations` or inline JSON.
- `item_server (item FK PK, export, extra JSON)`
- `item_buttons (item FK, sort, label, group_name, export)`. Points at `resource.export`
  (see Q1).

**weapons**
- `weapons (name PK, enabled, label, weight, durability, ammoname, model, throwable, extra JSON)`
- `weapon_components (name PK, enabled, label, type, weight, usetime, extra JSON)`
- `weapon_component_hashes (component FK, hash_name)`. The `client.component` list.
- `weapon_ammo (name PK, enabled, label, weight, extra JSON)`
- `weapon_tints (name PK, enabled, label, weight, tint, extra JSON)`

**shops**
- `shops (type PK, enabled, name, label, icon, model JSON, blip_id, blip_colour, blip_scale, extra JSON)`
- `shop_groups (shop FK, group_name, grade)`
- `shop_items (shop FK, sort, name, price, count, currency, license, grade, metadata JSON)`
- `shop_locations (shop FK, idx, x, y, z, heading, ped, scenario,
  target_x/y/z, target_length, target_width, target_heading, target_minz, target_maxz, target_distance)`.
  Upstream's parallel `locations[i]` and `targets[i]` arrays become one row each.

**stashes**
- `stashes (name PK, enabled, label, owner, slots, weight, x, y, z, target_* columns, target_label, extra JSON)`
- `stash_groups (stash FK, group_name, grade)`. `@police` expands to `shared.police`.

**crafting**
- `crafting_benches (name PK, enabled, label, blip_id, blip_colour, blip_scale, extra JSON)`
- `crafting_bench_groups (bench FK, group_name, grade)`
- `crafting_recipes (id PK, bench FK, sort, item, count, duration, metadata JSON, extra JSON)`
- `crafting_ingredients (recipe FK, item, amount DECIMAL)`. An amount below 1 means durability
  cost, as upstream treats it.
- `crafting_points (bench FK, idx, x, y, z)`
- `crafting_zones (bench FK, idx, x, y, z, size_x/y/z, rotation, distance, label, icon, groups JSON)`

**evidence**: `evidence_lockers (id PK, enabled, x, y, z, target_* columns, extra JSON)`

**licenses**: `licenses (name PK, enabled, x, y, z, price)`

**vehicles**
- `vehicle_storage (model PK, flag TINYINT)`. 0 to 3, the same meaning as upstream.
- `vehicle_class_capacity (container ENUM('glovebox','trunk'), class TINYINT, slots, max_weight, PK(container,class))`
- `vehicle_model_capacity (container, model, slots, max_weight, PK(container,model))`
- `vehicle_trunk_bones (model PK, bone_index)`

**animations**
- `animations (name PK, dict, clip, flag, extra JSON)`
- `animation_props (name PK, model, pos_x/y/z, rot_x/y/z, bone, extra JSON)`

Migrations are plain SQL files in `sql/dbconfig/NNN_*.sql`, applied in order at startup,
following the `CREATE TABLE IF NOT EXISTS` / `SHOW COLUMNS` pattern that
`modules/mysql/server.lua` already uses.

---

## 6. Runtime design

### 6.1 New module `modules/dbconfig/`
- `shared.lua`: `get(name)` returns the effective config. It holds the current tables and lets
  each config register an `apply(new, old)` handler.
- `server.lua`
  - `loaders/<name>.lua`: one per config. Turns rows into the exact Lua shape upstream
    expects: `vec3`, hashes, `@police` expansion, the parallel-array shape for shops, and so on.
  - `validate.lua`: checks referential and type integrity. Shop, recipe and ingredient items
    must exist, ammo names must resolve, and so on. **If any check fails, the reload is aborted
    and the previous config stays live.**
  - Builds a serializable client payload: no functions, server-only fields such as
    `item.server` removed, sorted by revision.
- `client.lua`: on startup it waits for `GlobalState['ox_inventory:cfgrev']`, then fetches the
  payload by callback (latent transfer for `items` and `weapons`). It runs before the modules
  that need it.
- `seed.lua`: the console command `invconfig seed [name]` copies the current
  `data/<name>.lua` into the DB (optional, see Q2).

### 6.2 Startup order
- Server: `init.lua` loads `dbconfig`. It runs migrations, loads the DB layer and merges it,
  all before `require 'server'`, and while `shared.ready = false` (upstream already holds
  players out during that window).
- Client: `require 'client'` waits on the dbconfig payload. Before the payload arrives,
  `lib.load` is never used for `data.*`.

### 6.3 Update command
`/invconfig reload [all|items|weapons|shops|stashes|crafting|evidence|licenses|vehicles|animations]`
- Allowed from the console and for ace `command.invconfig` (default `group.admin`). Also exported
  as `exports.ox_inventory:ReloadConfig(name)`.
- Steps: load → validate → diff against the current config → server `apply()` → bump the
  revision → `TriggerLatentClientEvent('ox_inventory:cfgUpdated', -1, name, payload)` → client
  `apply()`. A reload that changes nothing does no client traffic.
- The reload reports a summary of what was added, changed and removed, and logs it with
  `lib.logger`.
- Optional (Q5): poll `ox_inv_cfg_meta.revision` every N seconds, for edits made by an external
  admin panel.

### 6.4 What `apply()` does for each config

| Config | Server | Client |
|---|---|---|
| items/weapons | Change `ItemList` entries in place, so existing references stay valid. Rebuild callbacks with `useExport`. Re-sync the ESX/QB item registry. | Change `Items` in place. Send the NUI an `updateItems` message (small web patch, Q6). Removed items show as unknown. |
| shops | Throw away `Shops[type]` (shops that were opened stay valid until closed) and re-run `registerShopType`. | Remove points, targets, peds and blips, then re-create them. |
| stashes | Rebuild `RegisteredStashes`. Open stash inventories keep their loaded size until they are unloaded (Q4). | Call `Inventory.Stashes()`. It already tears down and re-creates. |
| crafting | Rebuild `CraftingBenches`. | Remove target zones, points and blips, then rebuild. |
| evidence | none | `Inventory.Evidence()` (already idempotent) |
| licenses | Swap the `Licenses` table. | Remove the license points, then re-create them. |
| vehicles | Swap the table. This affects inventories created after the reload. | Swap the table. |
| animations | none | Swap the table, then re-run the item anim/prop resolution in `client.lua:357-385`. |

Items that are removed while a player holds them are **not** deleted from inventories. They
become unusable "unknown item" entries, as upstream does today when an item is missing (Q3).

### 6.5 Fork changes to upstream behavior
- The ESX/QB item import (`modules/items/server.lua:77-107`) writes to the DB instead of
  `data/items.lua`.
- `RegisterShop` and the other runtime exports keep working. Shops registered at runtime live in
  memory only, and a reload keeps them (they are tracked apart from DB shops).

---

## 7. Implementation phases

1. **Foundation**: the `dbconfig` module, migrations, meta table, kill switch, and the swap of
   every call site to `get()`, with the DB empty (so behavior is identical to upstream). The
   payload is sent to clients. Includes a CI check for stray `lib.load('data.*')` calls.
2. **Simple configs**: licenses, evidence, animations, vehicles, with loaders, validation and
   hot reload.
3. **Stashes and crafting**: child tables, teardown/apply.
4. **Shops**: parallel-array normalization, peds and targets.
5. **Items and weapons**: the largest part. Includes the NUI patch, framework bridge re-sync,
   and the function/export bridge.
6. **Tooling**: `invconfig seed`, `invconfig export` (DB → Lua file, for diffs and backups),
   the rebase checklist, and docs.

Each phase is a separate PR.

---

## 8. Risks

- **Rebase conflicts in the modules where hot reload is added** (shops, crafting, licenses).
  Mitigation: keep the hunks small and send the refactors upstream.
- **Payload size**: `weapons` and `items` can reach hundreds of KB. Use latent events, send
  only the configs that changed, and optionally compress.
- **Clients that join during a reload**: they must get the current revision. They always fetch
  by revision, so no partial state reaches them.
- **Third-party resources that cache `exports.ox_inventory:Items()` results** will see old
  data. The fork fires the event `ox_inventory:configReloaded(name)` so they can refresh.

---

## 9. Open questions (answers needed before implementation)

**Q1. Item functions.** `buttons[].action` and other Lua callbacks can't be stored in SQL.
Options: (a) the DB stores an export reference (`resource.export`) and the fork wraps it
*(recommended)*; (b) items that need functions stay defined in Lua only; (c) both.

**Q2. Source of truth.** Options: (a) layered: upstream files as base, DB overrides and adds,
`enabled=0` tombstones *(recommended, because upstream weapon and item additions then arrive
automatically)*; (b) DB only: seed once from the files, then ignore them (new upstream items
must be imported by hand on each update).

**Q3. Items deleted at runtime that players still hold.** Options: (a) keep them in
inventories as unknown items *(recommended, matches upstream)*; (b) purge them; (c) refuse the
reload if any are in use.

**Q4. Stashes or shops whose size changes while they are open.** Options: (a) the change
applies when the stash next loads *(recommended)*; (b) force-close open instances and resize.

**Q5. Change detection.** Options: (a) the manual command or export only *(recommended)*;
(b) also poll the revision table for an external admin panel.

**Q6. Web UI patch.** To update item labels, weights and images live, the NUI needs one new
message handler (about 10 lines under `web/src`, which then needs a rebuild). Is a small
`web/` diff acceptable? The alternative is to re-send the `init` message, which resets an
open UI.

**Q7. Normalization depth.** The schema in §5 normalizes the fields you'd normally edit and
puts the rest in `extra JSON`. Do you want *full* normalization (more tables, more upstream
drift to track), or this hybrid?

**Q8. Scope.** Should the `inventory:*` convars (e.g. `vehicleloot`, `dumpsterloot`, `police`,
`accounts`) also move to the DB, or stay as convars?

**Q9. Permissions and naming.** Command name `invconfig`, ace `command.invconfig`, table prefix
`ox_inv_cfg_`: OK?
