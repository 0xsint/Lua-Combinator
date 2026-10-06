-- ===========================================================================
-- data.lua  –  Lua Combinator prototype definitions
-- ===========================================================================

-- ---- Sprite tinting helper -----------------------------------------------
-- Recursively add a tint to every sprite layer so the entity is visually
-- distinct (teal/cyan instead of the vanilla constant-combinator yellow).
local function apply_tint(t, tint)
    if type(t) ~= "table" then return end
    -- Direct sprite: add tint to any table that has a filename
    if t.filename then t.tint = tint end
    -- Recurse into numbered array entries (e.g. SpriteVariations)
    for i = 1, #t do apply_tint(t[i], tint) end
    -- Recurse into named sub-structures
    for _, key in ipairs{"layers", "hr_version", "north", "south", "east", "west", "sheets"} do
        if t[key] then apply_tint(t[key], tint) end
    end
end

-- ---- Deep-copy vanilla decider combinator ----
local entity = table.deepcopy(data.raw["decider-combinator"]["decider-combinator"])

entity.name           = "lua-combinator"
entity.minable.result = "lua-combinator"

-- Tint: teal-cyan to make it obviously different at a glance
local TINT = {r = 0.15, g = 0.90, b = 0.85, a = 1.0}
apply_tint(entity.sprites,               TINT)
apply_tint(entity.activity_led_sprites,  TINT)

-- ---- Item ----------------------------------------------------------------
local item = {
    type        = "item",
    name        = "lua-combinator",
    icons = {
        {
            icon      = "__base__/graphics/icons/decider-combinator.png",
            icon_size = 64,
            tint      = TINT,
        }
    },
    subgroup      = "circuit-network",
    order         = "c[combinators]-d[lua-combinator]",
    place_result  = "lua-combinator",
    stack_size    = 50,
}

-- ---- Recipe --------------------------------------------------------------
local recipe = {
    type    = "recipe",
    name    = "lua-combinator",
    enabled = false,
    ingredients = {
        {type = "item", name = "constant-combinator", amount = 1},
        {type = "item", name = "advanced-circuit",    amount = 3},
        {type = "item", name = "processing-unit",     amount = 1},
    },
    results = {
        {type = "item", name = "lua-combinator", amount = 1},
    },
}

-- ---- Technology ----------------------------------------------------------
local technology = {
    type = "technology",
    name = "lua-combinator",
    icon      = "__base__/graphics/technology/circuit-network.png",
    icon_size = 256,
    prerequisites = {"circuit-network"},
    unit = {
        count = 150,
        ingredients = {
            {"automation-science-pack", 1},
            {"logistic-science-pack",   1},
            {"chemical-science-pack",   1},
        },
        time = 30,
    },
    effects = {
        {type = "unlock-recipe", recipe = "lua-combinator"},
    },
}

-- ---- Register everything -------------------------------------------------
data:extend{entity, item, recipe, technology}
