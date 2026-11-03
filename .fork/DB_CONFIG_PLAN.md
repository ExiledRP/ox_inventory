# Fork plan: database-driven `/data` configuration with hot reload

Status: **DRAFT rev 3. Waiting on a decision about the metadata storage (§10). Everything else is decided (§9).**
Base: upstream `overextended/ox_inventory` v2.48.1 (`39d4cc7`)

---

## 1. Goals

1. Every config file in `data/` is backed by its own database table, plus child tables for nested
   options. **No JSON columns.** Every expected field gets a real, typed column.
2. **The database alone can hold the whole configuration**, with nothing left in Lua files. Lua
   callbacks are replaced by stored export references.
3. Config can be changed while the server runs. `/invconfig reload` re-reads, checks and applies
   it on the server and on every client, with no restart.
4. **Keep the fork easy to rebase on upstream releases.** When an upstream release adds a config
   field, the fork gets a schema migration that adds the column (§3.6). It does not fall back to a
   catch-all column.

---

## 2. What upstream does today

Upstream reads each data file with `lib.load('data.<name>')` once, when the module loads. No
module can reload its data. Clients read the same Lua files themselves, because `fxmanifest.lua`
ships `data/*.lua` in `files {}`.

| Data file | Read in (server) | Read in (client) | What it builds |
|---|---|---|---|
| `items.lua` | `modules/items/shared.lua:109`, `modules/bridge/esx/server.lua:12` | `modules/items/shared.lua:109` | `ItemList`; ESX status sync |
| `weapons.lua` (`Weapons`, `Components`, `Ammo`; code also supports `Tints`) | `modules/items/shared.lua:76` | same | weapon, component, ammo and tint items |
| `shops.lua` | `modules/shops/server.lua:111` | `modules/shops/client.lua:7` | `Shops`, points or targets, peds, blips |
| `stashes.lua` | `modules/inventory/server.lua:83` | `modules/inventory/client.lua:360` | `RegisteredStashes`; zones/points |
| `crafting.lua` | `modules/crafting/server.lua:46` | `modules/crafting/client.lua:96` | `CraftingBenches`; zones/points/blips |
| `evidence.lua` | none | `modules/inventory/client.lua:321` | evidence zones/points |
| `licenses.lua` | `server.lua:361` | `client.lua:1325` | license purchase points |
| `vehicles.lua` | `modules/inventory/server.lua:80` | `client.lua:123`, `modules/inventory/client.lua:51` | trunk/glovebox capacity, storage flags |
| `animations.lua` | none | `client.lua:357` | anim/prop lookup for item use |

Things that shape the design:
- Several item fields are **Lua functions**: `buttons[].action`, `client.add`, `client.remove`,
  and anything set through the client `Item(name, cb)` helper. A database can't store functions,
  so the database form stores a `resource.export` reference instead (§5.0).
- Some values are worked out when the file loads: `` `hash` `` literals, `vec3(...)`, `shared.police`.
  The database stores names and plain numbers, and the loader converts them.
- Several fields accept **more than one shape**:
  - `groups`: a string, a list, or a `{name = grade}` map.
  - `grade`: a number or a list.
  - target zones: the legacy shape (`loc`/`length`/`width`/`heading`/`minZ`/`maxZ`) or
    `coords`/`size`/`rotation`.
  - `anim`: a name reference or an inline table.
  - `prop`: a name, a table, or a list of either.

  §5 gives each one a single relational shape.
- `modules/items/server.lua:77-107` (ESX/QB item import) **writes back to `data/items.lua`**.
- The NUI receives item data once, in the `init` message (`client.lua:1341`); see Q6.

---

## 3. Upstream compatibility strategy

1. **Leave `data/*.lua` untouched.** These files are the default base layer, and upstream edits to
   them merge with no conflict.
2. **Put fork code in new paths only:** `modules/dbconfig/**`, `sql/dbconfig/**`, `.fork/**`.
3. **Keep upstream edits small and marked with `-- [fork:dbconfig]`.**
   - `fxmanifest.lua`: one `files` entry.
   - The ~14 `lib.load('data.X')` call sites become `require 'modules.dbconfig'.get('X')`.
   - Reload hooks. `Inventory.Stashes()` and `Inventory.Evidence()` already tear down and
     re-create, so the fork reuses them. Shops, crafting and licenses build everything inline at
     module load, so the loop body moves into a local function the fork can call again. These are
     the riskiest hunks for rebases. Offer them upstream as "allow re-registering" PRs.
4. **Kill switch.** The convar `inventory:dbconfig 0` turns the fork off and gives exact upstream
   behavior.
5. **Rebase checklist** (`.fork/REBASE.md`) plus CI:
   - Fail the build on any `lib.load('data.` hit outside `modules/dbconfig`.
   - Run `invconfig audit` against the new upstream `data/*.lua` (§3.6).
6. **Schema drift policy.** `invconfig audit` walks every `data/*.lua` file and lists every key
   that has no column mapping. A new upstream field therefore turns CI red until someone adds a
   numbered migration in `sql/dbconfig/` and maps the field in the loader. Data is never stored
   in an untyped column.

---

## 4. Layering (decided)

```
effective config = data/<file>.lua (base, if enabled for that config)
                 ⊕ DB rows (override or add, per entity key; DB wins)
                 − DB rows with enabled = 0 (tombstone: hides a base entry)
```

- `ox_inventory_config_sources (config PK, use_file_base BOOL DEFAULT 1)`: setting a row to 0
  makes the **database the only source** for that config.
- A DB row replaces the matching base entity whole, child rows included. Fields are not merged one
  by one.
- Entity keys: item, weapon, component, ammo or tint name; shop type; stash name; bench name;
  license name; evidence locker name; vehicle model or class; anim or prop name.
- The seed command `invconfig seed <config|all> [--overwrite]` copies the current file layer into
  the database. It converts legacy shapes into the canonical columns. The seed is how a server
  moves to database-only config.

---

## 5. Schema

Conventions:
- Every table is named `ox_inventory_config_<name>`. They use InnoDB, `utf8mb4`, and
  `ON DELETE CASCADE` foreign keys. Every table has `updated_at`.
- Coordinates are `*_x/*_y/*_z DOUBLE`.
- Model, weapon and component hashes are stored as their **name** (`VARCHAR`), with a nullable
  `*_hash INT` for a raw hash when no name is known. The loader runs `joaat()`.
- `sort` columns keep upstream's list order, because shop slots and recipe slots depend on it.
- Nullable columns mean "not set". The loader leaves those keys out, so upstream defaults
  (`stack = true`, `close = true`, `disable.combat = true`, ...) still apply.

### 5.0 Shared shapes

**Export references.** A `VARCHAR(128)` holding `resource.exportName`, the same format upstream
already uses for `client.export` and `server.export`. The loader turns it into
`function(...) return exports[res][fn](nil, ...) end`. A reference to a resource that isn't
running doesn't fail the load; it shows up as a warning in the reload report.

**Groups** (used by shops, stashes, crafting benches and crafting zones). Each owner gets its own
child table: `(<owner FK>, group_name VARCHAR(64), min_grade INT DEFAULT 0)`. The loader always
emits the `{name = grade}` map, which upstream's `hasGroup` accepts. The special `group_name` value
`@police` expands to the current `shared.police` groups.

**Box zone columns** (used wherever upstream has `target`/`targets`/`zones`): `zone_x, zone_y,
zone_z, zone_size_x, zone_size_y, zone_size_z, zone_rotation, zone_distance, zone_label, zone_icon,
zone_icon_color`. The seed converts the legacy `loc`/`length`/`width`/`minZ`/`maxZ` shape with the
same math as `Utils.CreateBoxZone`. The loader also sets `loc = coords`, so the server's distance
checks keep working.

**Blip columns:** `blip_id, blip_colour, blip_scale` (all nullable; no blip when `blip_id` is
NULL).

### 5.1 items
| Table | Columns |
|---|---|
| `items` | `name PK, enabled, label, weight INT, stack BOOL NULL, close BOOL NULL, description TEXT NULL, degrade INT NULL, decay BOOL NULL, consume DECIMAL(6,3) NULL, allow_armed BOOL NULL` |
| `item_client` (1:1) | `item PK FK, image, label (progress label), usetime INT, cancel BOOL, use_while_dead BOOL, notification, export, event, add_export, remove_export, effect_export, scenario, anim_ref, anim_dict, anim_clip, anim_flag INT, anim_blend_in DECIMAL, anim_blend_out DECIMAL, anim_duration INT, anim_playback_rate DECIMAL, anim_lock_x BOOL, anim_lock_y BOOL, anim_lock_z BOOL, anim_play_enter BOOL, disable_move BOOL, disable_car BOOL, disable_combat BOOL, disable_mouse BOOL, disable_sprint BOOL` |
| `item_client_props` | `item FK, sort, prop_ref NULL, model, bone INT, pos_x/y/z, rot_x/y/z, rot_order INT`. One row per prop; this covers `prop`, `propTwo` and prop lists. |
| `item_client_status` | `item FK, status VARCHAR(32), value INT`. Status names (`hunger`, `thirst`, `stress`, ...) are defined by the framework, so each one is a row. |
| `item_server` (1:1) | `item PK FK, export` |
| `item_buttons` | `item FK, sort, label, group_name NULL, export`. The export is called with `slot`, as `action(slot)` is today. |

`effect_export` stands in for the client `Item(name, cb)` helper. `anim_ref` and `prop_ref` point
at the `animations` tables (§5.9).

### 5.2 weapons
| Table | Columns |
|---|---|
| `weapons` | `name PK, enabled, label, weight, durability DECIMAL(6,4), ammoname NULL, model NULL, throwable BOOL NULL, image NULL, description NULL, unholster_dict, unholster_clip, unholster_time INT, holster_dict, holster_clip, holster_time INT` |
| `weapon_components` | `name PK, enabled, label, type, weight, usetime INT, image, description` |
| `weapon_component_hashes` | `component FK, sort, hash_name, hash INT NULL` |
| `weapon_ammo` | `name PK, enabled, label, weight, image, description` |
| `weapon_tints` | `name PK, enabled, label, weight, tint INT, usetime INT, image, description` |

The six `*holster*` columns hold upstream's six-element `anim` tuple on weapons.

### 5.3 shops
| Table | Columns |
|---|---|
| `shops` | `type PK, enabled, name, label NULL, icon NULL, blip_*` |
| `shop_groups` | groups shape |
| `shop_models` | `shop FK, sort, model, model_hash NULL` (vending-machine style shops) |
| `shop_items` | `id PK AUTO_INCREMENT, shop FK, sort, item, price INT, count INT NULL, currency NULL, license NULL, min_grade INT NULL, UNIQUE(shop, sort)` |
| `shop_item_grades` | `shop_item FK, grade INT`. This holds the list form of `grade`. If any rows exist, they win over `min_grade`. |
| `shop_item_metadata` | `shop_item FK, meta_key, value_type ENUM('string','number','boolean'), value_string, value_number DOUBLE, value_bool, PK(shop_item, meta_key)`. Worked example: `.fork/examples/item_metadata.sql`. |
| `shop_locations` | `shop FK, sort, x, y, z, heading, ped, ped_hash NULL, scenario` + box zone columns. One row per location; this holds upstream's parallel `locations[i]`/`targets[i]` arrays together. |

### 5.4 stashes
`stashes (name PK, enabled, label, owner BOOL, slots, weight, x, y, z, distance` + box zone
columns`)` and `stash_groups`.

### 5.5 crafting
| Table | Columns |
|---|---|
| `crafting_benches` | `name PK, enabled, label NULL, blip_*` |
| `crafting_bench_groups` | groups shape |
| `crafting_recipes` | `id PK AUTO_INCREMENT, bench FK, sort, item, count INT, duration INT, UNIQUE(bench, sort)` |
| `crafting_ingredients` | `recipe FK, item, amount DECIMAL(10,4)`. An amount below 1 means durability cost, as upstream treats it. |
| `crafting_recipe_metadata` | `recipe FK`, plus the same typed key/value columns as `shop_item_metadata` |
| `crafting_points` | `bench FK, sort, x, y, z` |
| `crafting_zones` | `bench FK, sort` + box zone columns |
| `crafting_zone_groups` | `bench FK, zone_sort, group_name, min_grade` |

### 5.6 evidence
`evidence_lockers (name PK, enabled, x, y, z` + box zone columns`)`. Upstream entries have no
names; the seed generates `evidence_<n>`.

### 5.7 licenses
`licenses (name PK, enabled, sort, x, y, z, price)`. `sort` keeps upstream's array index, which the
`buyLicense` callback uses as the license id.

### 5.8 vehicles
| Table | Columns |
|---|---|
| `vehicle_storage` | `model PK, model_hash NULL, flag TINYINT` (0 to 3, the same meaning as upstream) |
| `vehicle_class_capacity` | `container ENUM('glovebox','trunk'), class TINYINT, slots, max_weight, PK(container, class)` |
| `vehicle_model_capacity` | `container, model, model_hash NULL, slots, max_weight, PK(container, model)` |
| `vehicle_trunk_bones` | `model PK, bone_index INT` |

### 5.9 animations
- `animations (name PK, dict, clip, flag, blend_in, blend_out, duration, playback_rate, lock_x/y/z, scenario, play_enter)`
- `animation_props (name PK, model, bone, pos_x/y/z, rot_x/y/z, rot_order)`

### 5.10 Metadata and control tables
- `ox_inventory_config_meta (config PK, revision INT, updated_at, updated_by)`
- `ox_inventory_config_sources`, see §4.
- `ox_inventory_config_migrations (version PK, applied_at)`

### 5.11 Typed key/value tables (please confirm)
`shop_item_metadata` and `crafting_recipe_metadata` are the only places where upstream allows
**any key a resource chooses** (for example `registered`, `serial`, `durability`, or a custom
key). The typed key/value tables have no JSON, but they also can't hold nested tables as values.
Upstream allows nested values but rarely uses them. The loader will reject nested values in the
seed and audit, and report them. `item_client_status` follows the same idea, but its values are
always integers.

---

## 6. Runtime design

### 6.1 `modules/dbconfig/`
- `shared.lua`: `get(name)` returns the current effective table. It holds the per-config
  `apply(new, old)` handlers.
- `server/loaders/<name>.lua`: one per config. Each turns rows into the exact Lua shape upstream
  expects.
- `server/validate.lua`: checks references (shop, recipe and ingredient items exist, `ammoname`
  resolves, `anim_ref`/`prop_ref` exist) and types. **Any error aborts the reload and leaves the
  previous config live.**
- `server/audit.lua`, `server/seed.lua`, `server/migrate.lua`.
- `client.lua`: waits for `GlobalState['ox_inventory:cfgrev']`, then fetches the payload over a
  callback, using latent transfer for `items` and `weapons`. It runs before the modules that need
  the payload. The payload contains no functions; export references are re-resolved on the client.

### 6.2 Startup
- Server: migrations run, then load, validate and merge, all before `require 'server'`. This
  happens while `shared.ready = false`, so upstream already holds joining players out.
- Client: `require 'client'` waits until the payload has arrived.

### 6.3 `/invconfig` command
Allowed from the console and for ace `command.invconfig`.

| Subcommand | Effect |
|---|---|
| `reload [all\|<config>]` | load → validate → diff → server `apply` → bump revision → latent broadcast → client `apply` |
| `seed <config\|all> [--overwrite]` | file layer → DB |
| `audit` | report file keys that have no column (see §3.6) |
| `status` | revision, source mode and entity counts for each config |

The same actions are available through exports, e.g. `exports.ox_inventory:ReloadConfig(name)`.
There is no polling (decided). Each reload logs a summary of what was added, changed and removed
with `lib.logger`, and fires `ox_inventory:configReloaded(name)` for third-party resources.

### 6.4 What `apply()` does for each config (all decided)
| Config | Server | Client |
|---|---|---|
| items/weapons | Change `ItemList` in place, re-resolve exports, re-sync the ESX/QB item registry. | Change `Items` in place, then send the NUI an `updateItems` message (Q6). |
| shops | Rebuild shop definitions. Shops that are open keep their contents until they next load (decided: *next load*). | Remove points, targets, peds and blips, then re-create them. |
| stashes | Rebuild `RegisteredStashes`. Loaded stash inventories keep their size until they unload. | `Inventory.Stashes()` |
| crafting | Rebuild `CraftingBenches`. | Remove zones, points and blips, then rebuild. |
| evidence | none | `Inventory.Evidence()` |
| licenses | Swap the `Licenses` table. | Remove the license points, then re-create them. |
| vehicles | Swap the table. Applies to inventories created after the reload. | Swap the table. |
| animations | none | Swap the table, then re-run the anim/prop resolution. |

**Items removed while players hold them** keep upstream behavior (decided). Upstream silently
skips slots whose item no longer exists when an inventory next loads (`Inventory.Load` and
`server.setPlayerInventory`), and does not touch inventories that are already loaded. The fork does the same and
names those items in the reload report.

### 6.5 Fork changes to upstream behavior
- The ESX/QB item import writes to the `items` tables instead of `data/items.lua`.
- `RegisterShop` and the other runtime exports still work. Shops registered at runtime live in
  memory only and survive a reload.

---

## 7. Implementation phases (one PR each)
1. **Foundation.** Migrations runner, `meta`/`sources` tables, kill switch, every call site changed
   to `get()` (behavior stays identical while the DB is empty), client payload delivery, CI check.
2. **Simple configs:** animations, licenses, evidence, vehicles.
3. **Stashes and crafting.**
4. **Shops.**
5. **Items and weapons:** export bridge, `updateItems` NUI message plus UI rebuild (Q6), framework re-sync.
6. **Tooling:** `seed`, `audit`, `status`, rebase checklist, docs.

---

## 8. Risks
- Rebase conflicts in the modules where the reload hooks are added. Keep those hunks small and
  send them upstream.
- Payload size for `items` and `weapons`. Use latent events and send only the configs that
  changed.
- Rows that override a base entity whole can hide fields upstream adds to that entity later. The
  audit flags overridden entities whose base gained new keys.
- Third-party resources that cache `Items()` results. They can listen for
  `ox_inventory:configReloaded`.

---

## 9. Decisions (answered)
| # | Decision |
|---|---|
| Q1 | Export references are stored in the DB, and the DB can be the only source of config. |
| Q2 | The files are the base layer and the DB takes priority. `use_file_base` can turn the files off per config. |
| Q3 | Keep upstream behavior for removed items. |
| Q4 | Size changes apply on next load. |
| Q5 | Reload by command only. |
| Q6 | **B:** a new `updateItems` NUI message (about 15 lines in `web/src`). The fork ships its own rebuilt `web/build`, built in CI. |
| Q7 | No JSON columns. Every expected field gets a column, and upstream drift gets a migration. |
| Q8 | Convars stay convars. Only the `data/` configs move to the database. |
| Q9 | `/invconfig`, ace `command.invconfig`, table prefix `ox_inventory_config_`. |

---

## 10. Open: storing metadata

Shop item metadata, crafting recipe metadata and `client.status` accept any key upstream. With no
JSON allowed, the plan stores them as typed key/value rows (§5.11). See
`.fork/examples/item_metadata.sql` for the full DDL, sample rows and the Lua the loader builds
from them.

Limitation: values must be a string, a number or a boolean. Nested tables (e.g.
`metadata = { components = { 'at_flashlight' } }`) are rejected by the validator. Upstream's own
data files don't use nested metadata.

**To decide:** accept the typed key/value rows, or choose another approach.
