-- ===========================================================================
-- tests/mock.lua  –  A minimal stand-in for the Factorio control stage
-- ===========================================================================
-- Just enough of the Factorio runtime to load control.lua and run scripts
-- outside the game.  Unknown prototype names are treated as existing unless
-- they start with "bogus", so examples can use any vanilla name.
-- ===========================================================================

local M = {}

-- ---- serpent (only what the mod uses) --------------------------------------
local function ser(v, indent, seen)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return tostring(v) end
    if seen[v] then return "nil --[[ref]]" end
    seen[v] = true
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
        return type(a) < type(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do
        local ks = type(k) == "string" and k or "[" .. tostring(k) .. "]"
        parts[#parts + 1] = ks .. " = " .. ser(v[k], indent, seen)
    end
    seen[v] = nil
    return "{" .. table.concat(parts, ", ") .. "}"
end
serpent = {
    line  = function(v) return ser(v, "", {}) end,
    block = function(v) return ser(v, "", {}) end,
}

-- ---- defines ------------------------------------------------------------------
local next_event_id = 0
local event_ids = setmetatable({}, {__index = function(t, k)
    next_event_id = next_event_id + 1
    rawset(t, k, next_event_id)
    return next_event_id
end})

defines = {
    events = event_ids,
    wire_connector_id = {
        combinator_input_red = 1, combinator_input_green = 2,
        combinator_output_red = 3, combinator_output_green = 4,
        circuit_red = 1, circuit_green = 2,
    },
    rocket_silo_status = {rocket_ready = 10, building_rocket = 1},
    flow_precision_index = {one_minute = 1},
}

-- ---- prototypes ------------------------------------------------------------------
local function proto_table(kind)
    return setmetatable({}, {__index = function(_, name)
        if type(name) ~= "string" or name:match("^bogus") then return nil end
        if kind == "virtual_signal" then
            if name:match("^signal%-") then return {name = name} end
            return nil
        end
        if kind == "item" then
            if name:match("^signal%-") or name == "water" or name == "steam" then return nil end
            return {name = name}
        end
        if kind == "fluid" then
            if name == "water" or name == "steam" or name == "crude-oil" then return {name = name} end
            return nil
        end
        if kind == "quality" then
            if name == "normal" or name == "rare" or name == "legendary" then return {name = name} end
            return nil
        end
        if kind == "entity" then return {name = name} end
        return nil
    end})
end
prototypes = {
    item = proto_table("item"), fluid = proto_table("fluid"),
    virtual_signal = proto_table("virtual_signal"), entity = proto_table("entity"),
    recipe = proto_table("recipe"), quality = proto_table("quality"),
}

-- ---- misc globals -----------------------------------------------------------------
M.logs, M.chat = {}, {}
log = function(s) M.logs[#M.logs + 1] = s end
table_size = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
settings = {global = {
    ["lua-combinator-default-interval"] = {value = 20},
    ["lua-combinator-error-marker"]     = {value = true},
    ["lua-combinator-error-chat"]       = {value = true},
}}

-- ---- rendering -------------------------------------------------------------------
local function render_object(params)
    local o = {valid = true, params = params}
    for k, v in pairs(params) do o[k] = v end
    function o.destroy() o.valid = false end
    return o
end
rendering = {
    draw_text = render_object, draw_sprite = render_object,
    draw_rectangle = render_object, draw_circle = render_object, draw_line = render_object,
}

-- ---- script / remote ---------------------------------------------------------
M.handlers, M.nth, M.lifecycle, M.interfaces = {}, {}, {}, {}
script = {
    on_event = function(id, fn) M.handlers[id] = fn end,
    on_nth_tick = function(n, fn) M.nth[n] = fn end,
    on_init = function(fn) M.lifecycle.init = fn end,
    on_load = function(fn) M.lifecycle.load = fn end,
    on_configuration_changed = function(fn) M.lifecycle.config = fn end,
}
remote = {
    add_interface = function(name, t) M.interfaces[name] = t end,
    call = function(name, fn, ...) return M.interfaces[name][fn](...) end,
}

-- ---- world ------------------------------------------------------------------------
M.entities = {}
local next_unit = 100

local function network(id, list)
    return {network_id = id, signals = list}
end

function M.make_force()
    local force = {
        name = "player", connected_players = {}, rockets_launched = 3,
        research_progress = 0.5, research_queue = {}, current_research = {name = "automation"},
    }
    force.print = function(msg) M.chat[#M.chat + 1] = msg end
    force.get_item_production_statistics = function()
        return {get_flow_count = function() return 12.5 end}
    end
    force.add_chart_tag = function(_, spec)
        return {valid = true, text = spec.text, destroy = function() end}
    end
    return force
end

function M.make_surface()
    return {
        name = "nauvis", darkness = 0.3, daytime = 0.4,
        get_pollution = function() return 42.5 end,
        count_entities_filtered = function() return 2 end,
        find_entities_filtered = function() return {} end,
    }
end

M.force   = M.make_force()
M.surface = M.make_surface()

--- Create a mock Lua Combinator.  inputs = {red = {...}, green = {...}} where
--- each list holds Factorio-style {signal = SignalID, count = n} entries.
function M.make_combinator(name)
    next_unit = next_unit + 1
    local e = {
        name = name or "lua-combinator", valid = true, unit_number = next_unit,
        position = {x = 0, y = 0}, surface = M.surface, force = M.force,
        inputs = {red = {}, green = {}}, outputs_seen = {red = {}, green = {}},
        param_writes = 0,
    }
    local store = {}
    e.behavior = setmetatable({}, {
        __index = store,
        __newindex = function(_, k, v)
            store[k] = v
            if k == "parameters" then e.param_writes = e.param_writes + 1 end
        end,
    })
    e.store = store
    e.get_or_create_control_behavior = function() return e.behavior end
    e.get_control_behavior = function() return e.behavior end
    e.get_circuit_network = function(wire)
        local W = defines.wire_connector_id
        if wire == W.combinator_input_red then return network(1, e.inputs.red) end
        if wire == W.combinator_input_green then return network(2, e.inputs.green) end
        if wire == W.combinator_output_red then return network(3, e.outputs_seen.red) end
        if wire == W.combinator_output_green then return network(4, e.outputs_seen.green) end
    end
    M.entities[e.unit_number] = e
    return e
end

--- Outputs currently configured on a mock entity as { "type/name" = count }.
function M.outputs_of(e)
    local r = {}
    local p = e.store.parameters
    if not p then return r end
    for _, o in ipairs(p.outputs or {}) do
        local key = (o.signal.type or "item") .. "/" .. o.signal.name
        if o.signal.quality then key = key .. "@" .. o.signal.quality end
        r[key] = o.constant
    end
    return r
end

function M.sig(name, count, sig_type, quality)
    return {signal = {type = sig_type, name = name, quality = quality}, count = count}
end

local players = {}
game = {
    tick = 0,
    print = function(msg) M.chat[#M.chat + 1] = msg end,
    get_player = function(i) return players[i] end,
    players = players,
    connected_players = {},
    get_entity_by_unit_number = function(u)
        local e = M.entities[u]
        return e and e.valid and e or nil
    end,
    forces = {player = M.force},
}

storage = {}

--- Advance the game by n ticks, firing on_tick and nth-tick handlers.
function M.tick(n)
    for _ = 1, n or 1 do
        game.tick = game.tick + 1
        local h = M.handlers[defines.events.on_tick]
        if h then h({tick = game.tick, name = defines.events.on_tick}) end
        for k, fn in pairs(M.nth) do
            if fn and game.tick % k == 0 then fn({tick = game.tick, nth_tick = k}) end
        end
    end
end

function M.raise(event_name, data)
    data = data or {}
    data.name = defines.events[event_name]
    data.tick = game.tick
    local h = M.handlers[data.name]
    if h then h(data) end
end

--- Snapshot of which events / nth ticks have a registered handler.
function M.registrations()
    local ev, nth = {}, {}
    for id, fn in pairs(M.handlers) do if fn then ev[#ev + 1] = id end end
    for n, fn in pairs(M.nth) do if fn then nth[#nth + 1] = n end end
    table.sort(ev); table.sort(nth)
    return table.concat(ev, ",") .. "|" .. table.concat(nth, ",")
end

--- Simulate saving and loading: drop all module state and handlers, then
--- re-run control.lua and on_load against the same storage.
function M.reload()
    for name in pairs(package.loaded) do
        if name:match("^scripts%.") or name:match("^examples%.") or name == "control" then
            package.loaded[name] = nil
        end
    end
    M.handlers, M.nth, M.lifecycle = {}, {}, {}
    require("control")
    M.lifecycle.load()
end

return M
