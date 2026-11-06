-- ===========================================================================
-- scripts/registry.lua  –  Combinator records and their lifecycle
-- ===========================================================================
--
-- storage.combinators[unit_number] = {
--     unit_number      = uint,
--     entity           = LuaEntity,
--     code             = string,
--     interval         = uint,     ticks between timer runs
--     run_on_timer     = bool,
--     output_enabled   = bool,
--     storage          = table,    the script's `storage`
--     helper_state     = table,    state of rising_edge(), average(), …
--     stats            = {runs, events, errors, last_run},
--     outputs          = table,    output buffer currently on the entity
--     output_signature = string,   change detection for outputs
--     last_error       = string|nil,
--     error_source     = "run"|"event"|nil,
--     next_run         = uint|nil, tick of the scheduled timer run
--     label            = LuaRenderObject|nil (label())
--     error_marker     = LuaRenderObject|nil
-- }
--
-- Configuration (code, interval, flags) travels with blueprints, copy/paste
-- and cloning.  Script `storage` intentionally does not.
-- ===========================================================================

local util      = require("scripts.util")
local outputs   = require("scripts.outputs")
local scheduler = require("scripts.scheduler")
local sandbox   = require("scripts.sandbox")

local registry = {}

local TAG = "lua_combinator"

local function setting(name)
    local s = settings.global[name]
    return s and s.value
end

local function default_interval()
    return setting("lua-combinator-default-interval") or 20
end

function registry.init()
    storage.combinators = storage.combinators or {}
    storage.open_guis   = storage.open_guis   or {}   -- [player_index] = unit_number
    storage.shared      = storage.shared      or {}   -- `shared` in scripts
    storage.channels    = storage.channels    or {}   -- transmit()/receive()
    scheduler.init()
end

function registry.get(unit)
    return storage.combinators[unit]
end

-- ---------------------------------------------------------------------------
-- Error marker / chat notification
-- ---------------------------------------------------------------------------

sandbox.on_error_changed = function(record)
    local entity = record.entity
    if record.error_marker and record.error_marker.valid then record.error_marker.destroy() end
    record.error_marker = nil
    if not (record.last_error and entity and entity.valid) then return end

    if setting("lua-combinator-error-marker") ~= false then
        record.error_marker = rendering.draw_sprite{
            sprite   = "utility/warning_icon",
            surface  = entity.surface,
            target   = {entity = entity, offset = {0, -0.3}},
            x_scale  = 0.5,
            y_scale  = 0.5,
        }
    end
    if setting("lua-combinator-error-chat") then
        local p = entity.position
        entity.force.print(string.format("[gps=%s,%s,%s] Lua Combinator #%d: %s",
            p.x, p.y, entity.surface.name, record.unit_number, record.last_error))
    end
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

--- The part of a record that is copied by blueprints/paste/clone.
function registry.export_config(record)
    return {
        code           = record.code,
        interval       = record.interval,
        run_on_timer   = record.run_on_timer,
        output_enabled = record.output_enabled,
    }
end

--- Apply a configuration (any subset of export_config's fields), re-register
--- event handlers, reschedule, and optionally run once immediately.
function registry.configure(record, cfg, run_now)
    if cfg.code ~= nil then record.code = tostring(cfg.code) end
    if cfg.interval ~= nil then
        record.interval = math.max(1, math.floor(tonumber(cfg.interval) or default_interval()))
    end
    if cfg.run_on_timer ~= nil then record.run_on_timer = cfg.run_on_timer and true or false end
    if cfg.output_enabled ~= nil then record.output_enabled = cfg.output_enabled and true or false end

    sandbox.clear_error(record)
    sandbox.setup(record, "apply")
    scheduler.reschedule(record, game.tick)
    if run_now and record.code ~= "" then
        sandbox.run(record, game.tick)
    else
        -- Output-enabled may have changed: re-apply the current buffer.
        outputs.apply(record, record.outputs or {})
    end
end

-- ---------------------------------------------------------------------------
-- Creation / removal
-- ---------------------------------------------------------------------------

local function new_record(entity)
    return {
        unit_number    = entity.unit_number,
        entity         = entity,
        code           = "",
        interval       = default_interval(),
        run_on_timer   = true,
        output_enabled = true,
        storage        = {},
        helper_state   = {},
        stats          = {runs = 0, events = 0, errors = 0},
        outputs        = {},
    }
end

function registry.create(entity, cfg)
    if not (entity and entity.valid and entity.name == util.ENTITY_NAME) then return nil end
    local unit = entity.unit_number
    local record = storage.combinators[unit]
    if not record then
        record = new_record(entity)
        storage.combinators[unit] = record
    end
    if cfg then
        registry.configure(record, cfg, false)
    end
    return record
end

function registry.remove(unit)
    local record = storage.combinators[unit]
    if not record then return end
    for _, key in ipairs{"label", "error_marker"} do
        local obj = record[key]
        if obj and obj.valid then obj.destroy() end
    end
    for name, channel in pairs(storage.channels) do
        channel[unit] = nil
        if next(channel) == nil then storage.channels[name] = nil end
    end
    storage.combinators[unit] = nil
    sandbox.forget(unit)
end

-- ---------------------------------------------------------------------------
-- Event handlers (wired up in control.lua)
-- ---------------------------------------------------------------------------

local function tags_config(tags)
    return tags and tags[TAG] or nil
end

function registry.on_built(e)
    local entity = e.entity or e.destination
    if entity and entity.valid and entity.name == util.ENTITY_NAME then
        registry.create(entity, tags_config(e.tags))
    end
end

function registry.on_removed(e)
    local entity = e.entity
    if entity and entity.valid and entity.name == util.ENTITY_NAME then
        registry.remove(entity.unit_number)
    end
end

function registry.on_cloned(e)
    local dst = e.destination
    if not (dst and dst.valid and dst.name == util.ENTITY_NAME) then return end
    local src = e.source and e.source.valid and storage.combinators[e.source.unit_number]
    registry.create(dst, src and registry.export_config(src) or nil)
end

function registry.on_settings_pasted(e)
    local src, dst = e.source, e.destination
    if not (dst and dst.valid and dst.name == util.ENTITY_NAME) then return end
    local dst_record = registry.create(dst)
    local src_record = src and src.valid and src.name == util.ENTITY_NAME and storage.combinators[src.unit_number]
    if src_record then
        registry.configure(dst_record, registry.export_config(src_record), true)
    else
        -- Pasting a vanilla decider overwrote our parameters: restore them.
        outputs.apply(dst_record, dst_record.outputs or {}, true)
    end
end

--- Store each combinator's configuration in the blueprint as entity tags.
function registry.on_player_setup_blueprint(e)
    local player = game.get_player(e.player_index)
    if not player then return end
    local mapping = e.mapping and e.mapping.valid and e.mapping.get()
    if not mapping then return end

    local candidates = {e.stack, e.record, player.blueprint_to_setup, player.cursor_stack}
    local target
    for _, c in pairs(candidates) do
        if c and c.valid and (c.object_name == "LuaRecord" or (c.valid_for_read and c.is_blueprint)) then
            target = c
            break
        end
    end
    if not target then return end

    for index, entity in pairs(mapping) do
        if entity.valid and entity.name == util.ENTITY_NAME then
            local record = storage.combinators[entity.unit_number]
            if record and record.code ~= "" then
                pcall(target.set_blueprint_entity_tag, index, TAG, registry.export_config(record))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Migration
-- ---------------------------------------------------------------------------

--- Bring every record up to the current format and rebuild runtime state.
function registry.migrate()
    registry.init()
    local units = {}
    for unit in pairs(storage.combinators) do units[#units + 1] = unit end
    table.sort(units)
    for _, unit in ipairs(units) do
        local record = storage.combinators[unit]
        if not (record.entity and record.entity.valid) then
            storage.combinators[unit] = nil
        else
            local from_old_version = record.stats == nil
            record.unit_number  = unit
            record.code         = record.code or ""
            record.interval     = math.max(1, math.floor(tonumber(record.interval) or default_interval()))
            record.storage      = record.storage or {}
            record.helper_state = record.helper_state or {}
            record.stats        = record.stats or {runs = 0, events = 0, errors = 0}
            record.outputs      = record.outputs or {}
            if record.output_enabled == nil then record.output_enabled = true end
            if record.run_on_timer   == nil then record.run_on_timer   = true end
            if from_old_version then
                -- Versions before 3.0 could pile up duplicate decider
                -- outputs; start from a clean slate.
                outputs.clear(record)
            end
            sandbox.setup(record, "load")
        end
    end
    scheduler.rebuild(storage.combinators, game.tick)
end

--- on_load: rebuild event handlers only (no storage writes allowed).
function registry.on_load()
    if not storage.combinators then return end
    local units = {}
    for unit in pairs(storage.combinators) do units[#units + 1] = unit end
    table.sort(units)
    for _, unit in ipairs(units) do
        sandbox.setup(storage.combinators[unit], "load")
    end
end

return registry
