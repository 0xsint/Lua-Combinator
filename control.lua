-- ===========================================================================
-- control.lua  –  Lua Combinator runtime entry point
-- ===========================================================================
-- This file only wires Factorio events to the modules in scripts/:
--
--   scripts/util.lua       shared helpers
--   scripts/signals.lua    reading circuit networks, signal names and types
--   scripts/outputs.lua    output buffers -> decider combinator parameters
--   scripts/events.lua     single event multiplexer for the mod + all scripts
--   scripts/scheduler.lua  tick buckets: only due combinators are visited
--   scripts/sandbox.lua    script API, compile cache, execution modes
--   scripts/registry.lua   combinator records, blueprints, paste, migration
--   scripts/gui.lua        code editor window and example browser
--   scripts/remote.lua     remote interface "lua-combinator"
--   examples/              built-in example scripts (see examples/index.lua)
--
-- Script-facing API: API_REFERENCE.md.
-- ===========================================================================

local events    = require("scripts.events")
local scheduler = require("scripts.scheduler")
local sandbox   = require("scripts.sandbox")
local registry  = require("scripts.registry")
local gui       = require("scripts.gui")
require("scripts.remote")

local E = defines.events

-- ---- Lifecycle ------------------------------------------------------------

script.on_init(function()
    registry.init()
end)

script.on_configuration_changed(function()
    registry.migrate()
end)

script.on_load(function()
    registry.on_load()
end)

-- ---- Main loop ----------------------------------------------------------------

local function run(record)
    local entity = record.entity
    if not (entity and entity.valid) then
        registry.remove(record.unit_number)
        return
    end
    sandbox.run(record, game.tick)
end

events.on(E.on_tick, function(e)
    scheduler.process(e.tick, storage.combinators, run)
    gui.on_tick(e.tick)
end)

-- ---- Building / removal -------------------------------------------------------

--- Event ids for the given names, skipping any this game version lacks.
local function existing(names)
    local r = {}
    for _, name in ipairs(names) do
        if E[name] then r[#r + 1] = E[name] end
    end
    return r
end

events.on(existing{
    "on_built_entity",
    "on_robot_built_entity",
    "script_raised_built",
    "script_raised_revive",
    "on_space_platform_built_entity",
}, registry.on_built)

events.on(existing{
    "on_player_mined_entity",
    "on_robot_mined_entity",
    "on_entity_died",
    "script_raised_destroy",
    "on_space_platform_mined_entity",
}, registry.on_removed)

events.on(E.on_entity_cloned, registry.on_cloned)
events.on(E.on_entity_settings_pasted, registry.on_settings_pasted)
events.on(E.on_player_setup_blueprint, registry.on_player_setup_blueprint)

-- ---- GUI ------------------------------------------------------------------------

events.on(E.on_gui_opened, gui.on_opened)
events.on(E.on_gui_closed, gui.on_closed)
events.on(E.on_gui_click, gui.on_click)
events.on(E.on_gui_checked_state_changed, gui.on_checked_state_changed)
events.on(E.on_gui_selection_state_changed, gui.on_selection_state_changed)
events.on(E.on_gui_selected_tab_changed, gui.on_tab_changed)
