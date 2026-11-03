-- Example: an item definition with client status values, and a shop entry that sells
-- the item with metadata. Draft DDL; final types and indexes are settled in phase 1.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE ox_inventory_config_items (
    name          VARCHAR(64)   NOT NULL PRIMARY KEY,
    enabled       BOOLEAN       NOT NULL DEFAULT 1,
    label         VARCHAR(100)  NOT NULL,
    weight        INT UNSIGNED  NOT NULL DEFAULT 0,
    stack         BOOLEAN       NULL,          -- NULL = upstream default (true)
    close         BOOLEAN       NULL,          -- NULL = upstream default (true)
    description   TEXT          NULL,
    degrade       INT UNSIGNED  NULL,          -- minutes
    decay         BOOLEAN       NULL,
    consume       DECIMAL(6,3)  NULL,
    allow_armed   BOOLEAN       NULL,
    updated_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- 1:1 with items. Only the columns used in this example are shown; the full list is in §5.1.
CREATE TABLE ox_inventory_config_item_client (
    item          VARCHAR(64)   NOT NULL PRIMARY KEY,
    image         VARCHAR(255)  NULL,
    usetime       INT UNSIGNED  NULL,
    anim_ref      VARCHAR(64)   NULL,          -- -> ox_inventory_config_animations.name
    notification  VARCHAR(255)  NULL,
    export        VARCHAR(128)  NULL,          -- 'resource.exportName'
    updated_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (item) REFERENCES ox_inventory_config_items (name) ON DELETE CASCADE ON UPDATE CASCADE
);

-- client.prop = 'burger' (or a list of props; one row each)
CREATE TABLE ox_inventory_config_item_client_props (
    item          VARCHAR(64)   NOT NULL,
    sort          TINYINT UNSIGNED NOT NULL,
    prop_ref      VARCHAR(64)   NULL,          -- -> ox_inventory_config_animation_props.name
    model         VARCHAR(64)   NULL,          -- inline prop, used when prop_ref is NULL
    bone          INT           NULL,
    pos_x DOUBLE NULL, pos_y DOUBLE NULL, pos_z DOUBLE NULL,
    rot_x DOUBLE NULL, rot_y DOUBLE NULL, rot_z DOUBLE NULL,
    rot_order     TINYINT       NULL,
    updated_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (item, sort),
    FOREIGN KEY (item) REFERENCES ox_inventory_config_items (name) ON DELETE CASCADE ON UPDATE CASCADE,
    CHECK (prop_ref IS NOT NULL OR model IS NOT NULL)
);

-- client.status = { hunger = 200000, thirst = -50000 }
CREATE TABLE ox_inventory_config_item_client_status (
    item          VARCHAR(64)   NOT NULL,
    status        VARCHAR(32)   NOT NULL,
    value         INT           NOT NULL,
    updated_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (item, status),
    FOREIGN KEY (item) REFERENCES ox_inventory_config_items (name) ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE ox_inventory_config_shops (
    type          VARCHAR(64)   NOT NULL PRIMARY KEY,
    enabled       BOOLEAN       NOT NULL DEFAULT 1,
    name          VARCHAR(100)  NOT NULL,
    label         VARCHAR(100)  NULL,
    icon          VARCHAR(64)   NULL,
    blip_id       INT           NULL,
    blip_colour   INT           NULL,
    blip_scale    DECIMAL(4,2)  NULL,
    updated_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- One row per shop slot (upstream `inventory = { ... }`).
CREATE TABLE ox_inventory_config_shop_items (
    id            INT UNSIGNED  NOT NULL AUTO_INCREMENT PRIMARY KEY,
    shop          VARCHAR(64)   NOT NULL,
    sort          SMALLINT UNSIGNED NOT NULL,  -- slot order
    item          VARCHAR(64)   NOT NULL,
    price         INT UNSIGNED  NOT NULL DEFAULT 0,
    count         INT UNSIGNED  NULL,          -- NULL = unlimited
    currency      VARCHAR(64)   NULL,          -- NULL = 'money'
    license       VARCHAR(64)   NULL,
    min_grade     INT           NULL,
    updated_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY (shop, sort),
    FOREIGN KEY (shop) REFERENCES ox_inventory_config_shops (type) ON DELETE CASCADE ON UPDATE CASCADE
    -- `item` is checked by the validator, not by a foreign key: the item may come from
    -- data/items.lua or data/weapons.lua instead of the DB.
);

-- metadata = { registered = true, serial = 'POL' }
CREATE TABLE ox_inventory_config_shop_item_metadata (
    shop_item     INT UNSIGNED  NOT NULL,
    meta_key      VARCHAR(64)   NOT NULL,
    value_type    ENUM('string','number','boolean') NOT NULL,
    value_string  VARCHAR(255)  NULL,
    value_number  DOUBLE        NULL,
    value_bool    BOOLEAN       NULL,
    updated_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (shop_item, meta_key),
    FOREIGN KEY (shop_item) REFERENCES ox_inventory_config_shop_items (id) ON DELETE CASCADE,
    CHECK (
        (value_type = 'string'  AND value_string IS NOT NULL AND value_number IS NULL AND value_bool IS NULL) OR
        (value_type = 'number'  AND value_number IS NOT NULL AND value_string IS NULL AND value_bool IS NULL) OR
        (value_type = 'boolean' AND value_bool   IS NOT NULL AND value_string IS NULL AND value_number IS NULL)
    )
);

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------

-- data/items.lua: ['burger']
INSERT INTO ox_inventory_config_items (name, label, weight)
VALUES ('burger', 'Burger', 220);

INSERT INTO ox_inventory_config_item_client (item, usetime, anim_ref, notification)
VALUES ('burger', 2500, 'eating', 'You ate a delicious burger');

INSERT INTO ox_inventory_config_item_client_props (item, sort, prop_ref)
VALUES ('burger', 1, 'burger');

INSERT INTO ox_inventory_config_item_client_status (item, status, value)
VALUES ('burger', 'hunger', 200000);

-- data/shops.lua: PoliceArmoury, slot 4
-- { name = 'WEAPON_PISTOL', price = 500, metadata = { registered = true, serial = 'POL' }, license = 'weapon' }
INSERT INTO ox_inventory_config_shops (type, name, blip_id, blip_colour, blip_scale)
VALUES ('PoliceArmoury', 'Police Armoury', 110, 84, 0.8);

INSERT INTO ox_inventory_config_shop_items (shop, sort, item, price, license)
VALUES ('PoliceArmoury', 4, 'WEAPON_PISTOL', 500, 'weapon');

SET @slot = LAST_INSERT_ID();

INSERT INTO ox_inventory_config_shop_item_metadata (shop_item, meta_key, value_type, value_string, value_number, value_bool)
VALUES (@slot, 'registered', 'boolean', NULL,  NULL, 1),
       (@slot, 'serial',     'string',  'POL', NULL, NULL);

-- ---------------------------------------------------------------------------
-- What the loader builds from these rows (identical to the upstream data files)
-- ---------------------------------------------------------------------------
-- items.burger = {
--     label = 'Burger', weight = 220,
--     client = {
--         status = { hunger = 200000 }, anim = 'eating', prop = 'burger',
--         usetime = 2500, notification = 'You ate a delicious burger',
--     },
-- }
--
-- shops.PoliceArmoury.inventory[4] = {
--     name = 'WEAPON_PISTOL', price = 500, license = 'weapon',
--     metadata = { registered = true, serial = 'POL' },
-- }
