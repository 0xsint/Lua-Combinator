-- ===========================================================================
-- scripts/remote.lua  –  remote.call("lua-combinator", ...) interface
-- ===========================================================================
-- Lets other mods, scenarios and console commands manage combinators in
-- bulk, e.g. deploying the same script to every combinator on a surface:
--
--   /c for _, u in pairs(remote.call("lua-combinator", "list")) do
--        remote.call("lua-combinator", "set_code", u, "out('signal-A', 1)")
--      end
-- ===========================================================================

local registry = require("scripts.registry")
local sandbox  = require("scripts.sandbox")
local examples = require("examples.index")

local function need(unit)
    local record = registry.get(unit)
    if not record then error("no Lua Combinator with unit number " .. tostring(unit), 3) end
    return record
end

local interface = {}

--- Sorted array of every Lua Combinator's unit number.
function interface.list()
    local units = {}
    for unit in pairs(storage.combinators) do units[#units + 1] = unit end
    table.sort(units)
    return units
end

function interface.get_code(unit) return need(unit).code end

--- set_code(unit, code [, {interval, run_on_timer, output_enabled}])
function interface.set_code(unit, code, options)
    local cfg = {code = code}
    for k, v in pairs(options or {}) do cfg[k] = v end
    registry.configure(need(unit), cfg, true)
    return need(unit).last_error
end

function interface.get_config(unit) return registry.export_config(need(unit)) end
function interface.get_storage(unit) return need(unit).storage end
function interface.set_storage(unit, value) need(unit).storage = value or {} end
function interface.get_error(unit) return need(unit).last_error end
function interface.get_stats(unit) return need(unit).stats end

--- Run once right now; returns the error message or nil.
function interface.run(unit)
    local record = need(unit)
    sandbox.run(record, game.tick)
    return record.last_error
end

--- Array of {id, category, title, description}.
function interface.examples()
    local r = {}
    for i, ex in ipairs(examples) do
        r[i] = {id = ex.id, category = ex.category, title = ex.title, description = ex.description}
    end
    return r
end

--- Load a built-in example into a combinator by id (e.g. "basics.clock").
function interface.load_example(unit, id)
    for _, ex in ipairs(examples) do
        if ex.id == id then
            return interface.set_code(unit, ex.code, {interval = ex.interval, run_on_timer = ex.timer})
        end
    end
    error("unknown example " .. tostring(id), 2)
end

remote.add_interface("lua-combinator", interface)

return interface
