-- ===========================================================================
-- scripts/sandbox.lua  –  Script environment, compile cache and execution
-- ===========================================================================
--
-- Design notes
-- ------------
-- * Compile once.  Each combinator's code is compiled a single time (and
--   again only when it changes) as
--       local _ENV = ...; <user code>
--   so the same compiled chunk can be called with a *fresh* environment on
--   every run.  Globals a script sets therefore never leak into the next
--   run, which matters in multiplayer: hidden state that is not in
--   `storage` would not exist on a peer that just joined.
--
-- * One shared API table.  All API functions (get_signal, set_output, …)
--   live in a single BASE table and act on the *current execution context*
--   (`ctx`).  Building an environment is a handful of rawsets instead of
--   creating ~60 closures per combinator per run.
--
-- * Lazy inputs.  Circuit networks are only read when a script actually
--   asks for them (red, green, get_signal, signals, …).
--
-- * Three execution modes:
--     "run"    timer tick, Apply, Run Now  – outputs rebuilt from scratch
--     "event"  script.on_event / on_nth_tick handler – starts from the
--              current outputs and only writes them if the handler
--              changed them
--     "setup"  registering handlers (on Apply and on every load) – inert:
--              no signals, no outputs, throwaway storage, no chat, and
--              `game`/`entity` are nil so Apply and load register exactly
--              the same handlers
-- ===========================================================================

local util    = require("scripts.util")
local signals = require("scripts.signals")
local outputs = require("scripts.outputs")
local events  = require("scripts.events")

local sandbox = {}

local compiled   = {}   -- [unit] = {code = string, fn = function|nil, err = string|nil}
local event_envs = {}   -- [unit] = environment the setup pass ran in
local ctx        = nil  -- current execution context

--- Hook called whenever a record's error state changes (set by registry).
sandbox.on_error_changed = function(record) end

-- ---------------------------------------------------------------------------
-- Context
-- ---------------------------------------------------------------------------

local function new_context(record, tick, mode)
    local inert = (mode == "setup")
    local entity = record.entity
    return {
        record   = record,
        unit     = record.unit_number,
        -- The setup pass must behave identically on Apply and on load (where
        -- game objects may not be touched), so it never sees the entity.
        entity   = (not inert and entity and entity.valid) and entity or nil,
        tick     = tick,
        mode     = mode,
        inert    = inert,
        storage  = inert and {} or record.storage,
        shared   = inert and {} or storage.shared,
        helpers  = inert and {} or record.helper_state,
        outputs  = (mode == "event") and outputs.copy(record.outputs) or {},
        touched  = false,
    }
end

local function current(fname)
    if not ctx then
        error(fname .. "() can only be used while a Lua Combinator script is running", 3)
    end
    return ctx
end

local function call_with(c, fn, ...)
    local prev = ctx
    ctx = c
    local ok, err = pcall(fn, ...)
    ctx = prev
    return ok, err
end

local EMPTY = {}

local function read_side(c, side)
    local cache_key = "_" .. side
    local r = c[cache_key]
    if r then return r end
    r = {}
    if c.entity and not c.inert then
        local wires = signals.WIRES[side]
        r.red,   r.red_list   = signals.read_network(c.entity.get_circuit_network(wires.red))
        r.green, r.green_list = signals.read_network(c.entity.get_circuit_network(wires.green))
    else
        r.red, r.red_list, r.green, r.green_list = {}, {}, {}, {}
    end
    c[cache_key] = r
    return r
end

-- ---------------------------------------------------------------------------
-- Error handling
-- ---------------------------------------------------------------------------

local function set_error(record, source, message)
    local changed = record.last_error ~= message
    record.last_error   = message
    record.error_source = source
    record.stats.errors = (record.stats.errors or 0) + 1
    if changed then sandbox.on_error_changed(record) end
end

local function clear_error(record, source)
    if record.last_error and (source == nil or record.error_source == source) then
        record.last_error   = nil
        record.error_source = nil
        sandbox.on_error_changed(record)
    end
end

-- ---------------------------------------------------------------------------
-- The API table every script sees
-- ---------------------------------------------------------------------------

local API = {}

-- ---- Inputs ---------------------------------------------------------------

local function lookup(side_fn, fname, name, color)
    if type(name) ~= "string" then
        error(fname .. " arg #1 (name) must be a string", 3)
    end
    local s = side_fn
    if color == nil then
        return (s.red[name] or 0) + (s.green[name] or 0)
    elseif color == "red" then
        return s.red[name] or 0
    elseif color == "green" then
        return s.green[name] or 0
    end
    error(fname .. " arg #2 (color) must be \"red\", \"green\" or nil", 3)
end

function API.get_signal(name, color)
    local v = lookup(read_side(current("get_signal"), "input"), "get_signal", name, color)
    return v
end

function API.get_output_signal(name, color)
    local v = lookup(read_side(current("get_output_signal"), "output"), "get_output_signal", name, color)
    return v
end

local function copy_records(list)
    local r = {}
    for i, s in ipairs(list) do
        r[i] = {type = s.type, name = s.name, quality = s.quality, count = s.count}
    end
    return r
end

--- signals([color [, side]]) -> sorted array of {type, name, quality, count}
function API.signals(color, side)
    local c = current("signals")
    side = side or "input"
    if side ~= "input" and side ~= "output" then
        error("signals arg #2 (side) must be \"input\" or \"output\"", 2)
    end
    local s = read_side(c, side)
    if color == "red" then return copy_records(s.red_list) end
    if color == "green" then return copy_records(s.green_list) end
    if color ~= nil then
        error("signals arg #1 (color) must be \"red\", \"green\" or nil", 2)
    end
    return signals.merge(s.red_list, s.green_list)
end

function API.get_network(color, side)
    local c = current("get_network")
    local by_side = signals.WIRES[side or "input"]
    if not by_side then
        error("get_network arg #2 (side) must be \"input\" or \"output\"", 2)
    end
    local wire = by_side[color]
    if not wire then
        error("get_network arg #1 (color) must be \"red\" or \"green\"", 2)
    end
    if not c.entity or c.inert then return nil end
    return c.entity.get_circuit_network(wire)
end

-- ---- Outputs --------------------------------------------------------------

--- Validate a signal; returns an error message or nil.
local function check_signal(sig_type, name, quality)
    if type(sig_type) ~= "string" then return "signal type must be a string" end
    if type(name) ~= "string" then return "signal name must be a string" end
    if not signals.PROTOTYPE_TABLES[sig_type] then
        return "unknown signal type \"" .. sig_type .. "\""
    end
    if sig_type == "virtual" and signals.WILDCARDS[name] then
        return "\"" .. name .. "\" is a wildcard and cannot be output"
    end
    if quality ~= nil and type(quality) ~= "string" then
        return "quality must be a string or nil"
    end
    if not signals.exists(sig_type, name) then
        return "unknown " .. sig_type .. " signal \"" .. name .. "\""
    end
    if not signals.quality_exists(quality) then
        return "unknown quality \"" .. quality .. "\""
    end
end

local function write(c, sig_type, name, quality, count, accumulate)
    if quality == "normal" then quality = nil end
    c.touched = true
    if c.inert then return end
    local err = check_signal(sig_type, name, quality)
    if err then error(err, 3) end
    local n = tonumber(count)
    if count ~= nil and n == nil then error("signal count must be a number", 3) end
    n = math.floor(n or 0)
    local key = outputs.key(sig_type, name, quality)
    local entry = c.outputs[key]
    if accumulate and entry then n = n + entry.count end
    if n == 0 then
        c.outputs[key] = nil
    elseif entry then
        entry.count = n
    else
        c.outputs[key] = {signal = {type = sig_type, name = name, quality = quality}, count = n}
    end
end

--- set_output(type, name, count [, quality])  or  set_output(SignalID, count)
function API.set_output(a, b, c3, d)
    local c = current("set_output")
    if c.inert then c.touched = true return end
    if type(a) == "table" then
        write(c, a.type or signals.resolve_type(a.name or ""), a.name, a.quality, b, false)
    else
        write(c, a, b, d, c3, false)
    end
end

--- add_output(type, name, delta [, quality])  or  add_output(SignalID, delta)
function API.add_output(a, b, c3, d)
    local c = current("add_output")
    if c.inert then c.touched = true return end
    if type(a) == "table" then
        write(c, a.type or signals.resolve_type(a.name or ""), a.name, a.quality, b, true)
    else
        write(c, a, b, d, c3, true)
    end
end

local function resolve_key(fname, key, quality)
    if type(key) ~= "string" then error(fname .. " arg #1 (name) must be a string", 3) end
    local name, q = signals.split_key(key)
    quality = quality or q
    local t = signals.resolve_type(name)
    if not t then error(fname .. ": no signal named \"" .. name .. "\"", 3) end
    return t, name, quality
end

--- out(name, count [, quality]) – set_output with the type worked out for you.
function API.out(name, count, quality)
    local c = current("out")
    if c.inert then c.touched = true return end
    local t, n, q = resolve_key("out", name, quality)
    write(c, t, n, q, count, false)
end

--- set_outputs{ ["iron-plate"] = 10, ["signal-A"] = 1, ["copper-plate@rare"] = 3 }
function API.set_outputs(map)
    local c = current("set_outputs")
    if type(map) ~= "table" then error("set_outputs arg #1 must be a table", 2) end
    if c.inert then c.touched = true return end
    for key, count in pairs(map) do
        local t, n, q = resolve_key("set_outputs", key)
        write(c, t, n, q, count, false)
    end
end

--- forward([color [, filter]]) – copy input signals to the output.
--- filter(sig) may return false/nil (drop), true (keep), or a number (new count).
function API.forward(color, filter)
    local c = current("forward")
    if type(color) == "function" then color, filter = nil, color end
    c.touched = true
    if c.inert then return end
    local list = API.signals(color)
    for _, s in ipairs(list) do
        if not (s.type == "virtual" and signals.WILDCARDS[s.name]) then
            local keep = true
            if filter then keep = filter(s) end
            if keep then
                local count = (type(keep) == "number") and keep or s.count
                write(c, s.type, s.name, s.quality, count, false)
            end
        end
    end
end

function API.clear_output()
    local c = current("clear_output")
    c.outputs = {}
    c.touched = true
end

--- get_outputs() -> { [key] = count } of what is queued so far.
function API.get_outputs()
    local c = current("get_outputs")
    local r = {}
    for _, e in pairs(c.outputs) do
        r[signals.key(e.signal.name, e.signal.quality)] = e.count
    end
    return r
end

-- ---- Chat, log and display ------------------------------------------------

local PRINT_COLOR = {r = 0.4, g = 1.0, b = 0.9}

function API.print(...)
    local c = current("print")
    if c.inert then return end
    game.print(util.join(tostring, ...), {color = PRINT_COLOR})
end

function API.dump(...)
    local c = current("dump")
    if c.inert then return end
    game.print(util.join(util.inspect, ...), {color = PRINT_COLOR})
end

function API.log(...)
    log(util.join(util.inspect, ...))
end

--- alert(message [, icon_signal [, show_on_map]]) – custom alert for the
--- combinator's force, pointing at the combinator.
function API.alert(message, icon, show_on_map)
    local c = current("alert")
    if c.inert or not c.entity then return end
    icon = icon or {type = "virtual", name = "signal-lua-combinator"}
    if type(icon) == "string" then
        local t = signals.resolve_type(icon)
        if not t then error("alert: no signal named \"" .. icon .. "\"", 2) end
        icon = {type = t, name = icon}
    end
    for _, player in pairs(c.entity.force.connected_players) do
        player.add_custom_alert(c.entity, icon, tostring(message), show_on_map ~= false)
    end
end

--- label(text [, options]) – floating text above the combinator.
--- options: color, scale, offset ({x, y}).  label(nil) removes it.
function API.label(text, opts)
    local c = current("label")
    if c.inert or not c.entity then return end
    local record = c.record
    local obj = record.label
    if text == nil then
        if obj and obj.valid then obj.destroy() end
        record.label = nil
        return
    end
    opts = opts or {}
    text = tostring(text)
    if obj and obj.valid then
        obj.text = text
        if opts.color then obj.color = opts.color end
        if opts.scale then obj.scale = opts.scale end
        return
    end
    record.label = rendering.draw_text{
        text         = text,
        surface      = c.entity.surface,
        target       = {entity = c.entity, offset = opts.offset or {0, -1.2}},
        color        = opts.color or {r = 0.4, g = 1.0, b = 0.9},
        scale        = opts.scale or 1,
        alignment    = "center",
        use_rich_text = true,
    }
end

-- ---- Pure helpers ---------------------------------------------------------

API.inspect       = util.inspect
API.clamp         = util.clamp
API.round         = util.round
API.format_number = util.format_number
API.rich_text     = signals.rich_text

function API.signal_type(name)
    if type(name) ~= "string" then return nil end
    return signals.resolve_type((signals.split_key(name)))
end

-- ---- State helpers (persisted per combinator, keyed by a name you pick) ---

local function state(kind)
    local c = current(kind)
    local h = c.helpers
    local t = h[kind]
    if not t then t = {} h[kind] = t end
    return t, c
end

--- true once, on the execution where `cond` turns from false to true.
function API.rising_edge(key, cond)
    local s = state("rising_edge")
    local prev = s[key]
    cond = cond and true or false
    s[key] = cond
    return cond and not prev
end

--- true once, on the execution where `cond` turns from true to false.
function API.falling_edge(key, cond)
    local s = state("falling_edge")
    local prev = s[key]
    cond = cond and true or false
    s[key] = cond
    return (not cond) and prev == true
end

--- changed(key, value) -> true, old_value when value differs from last call.
function API.changed(key, value)
    local s = state("changed")
    local old = s[key]
    s[key] = value
    if old ~= value then return true, old end
    return false, old
end

--- hysteresis(key, value, low, high): on when value >= high, off when <= low.
function API.hysteresis(key, value, low, high)
    local s = state("hysteresis")
    if value >= high then s[key] = true
    elseif value <= low then s[key] = false end
    return s[key] == true
end

--- latch(key, set, reset): SR latch, reset wins.
function API.latch(key, set, reset)
    local s = state("latch")
    if reset then s[key] = false elseif set then s[key] = true end
    return s[key] == true
end

--- every(ticks) / every(key, ticks): true at most once per `ticks` ticks.
function API.every(key, ticks)
    if ticks == nil then ticks, key = key, "#" .. tostring(key) end
    local s, c = state("every")
    local last = s[key]
    if last == nil or c.tick - last >= ticks then
        s[key] = c.tick
        return true
    end
    return false
end

--- delay(key, cond, ticks): true once `cond` has been true for `ticks` ticks.
function API.delay(key, cond, ticks)
    local s, c = state("delay")
    if not cond then s[key] = nil return false end
    if s[key] == nil then s[key] = c.tick end
    return c.tick - s[key] >= ticks
end

--- average(key, value, samples): moving average over the last `samples` calls.
function API.average(key, value, samples)
    local s = state("average")
    samples = math.max(1, math.floor(samples or 10))
    local b = s[key]
    if not b or b.n ~= samples then b = {n = samples, i = 0, sum = 0, vals = {}} s[key] = b end
    b.i = b.i % samples + 1
    b.sum = b.sum - (b.vals[b.i] or 0) + value
    b.vals[b.i] = value
    return b.sum / math.min(#b.vals, samples)
end

--- ema(key, value, alpha): exponential moving average (alpha 0..1).
function API.ema(key, value, alpha)
    local s = state("ema")
    local prev = s[key]
    if prev == nil then s[key] = value return value end
    local v = prev + (alpha or 0.1) * (value - prev)
    s[key] = v
    return v
end

--- rate(key, value): change of `value` per second since the previous call.
function API.rate(key, value)
    local s, c = state("rate")
    local prev = s[key]
    s[key] = {value = value, tick = c.tick}
    if not prev or c.tick == prev.tick then return 0 end
    return (value - prev.value) * 60 / (c.tick - prev.tick)
end

--- pid(key, setpoint, measured, kp, ki, kd [, min, max]) -> control output.
function API.pid(key, setpoint, measured, kp, ki, kd, min, max)
    local s, c = state("pid")
    local p = s[key]
    if not p then p = {integral = 0, last_error = nil, tick = c.tick} s[key] = p end
    local dt = math.max(1, c.tick - p.tick) / 60
    local err = setpoint - measured
    p.integral = p.integral + err * dt
    local deriv = p.last_error and (err - p.last_error) / dt or 0
    p.last_error, p.tick = err, c.tick
    local u = (kp or 0) * err + (ki or 0) * p.integral + (kd or 0) * deriv
    if min and u < min then
        u = min
        p.integral = p.integral - err * dt  -- anti-windup
    elseif max and u > max then
        u = max
        p.integral = p.integral - err * dt
    end
    return u
end

-- ---- Wireless channels ----------------------------------------------------
-- storage.channels[channel][unit] = { [key] = count }
-- receive() sums every transmitter on the channel, like a circuit network.

--- transmit(channel, { [key] = count }) – replace this combinator's
--- contribution to a channel.  transmit(channel, nil) stops transmitting.
function API.transmit(channel, values)
    local c = current("transmit")
    if c.inert then return end
    if type(channel) ~= "string" and type(channel) ~= "number" then
        error("transmit arg #1 (channel) must be a string or number", 2)
    end
    local ch = storage.channels[channel]
    if values == nil then
        if ch then
            ch[c.unit] = nil
            if next(ch) == nil then storage.channels[channel] = nil end
        end
        return
    end
    if type(values) ~= "table" then error("transmit arg #2 must be a table or nil", 2) end
    local copy = {}
    for k, v in pairs(values) do
        local n = math.floor(tonumber(v) or 0)
        if n ~= 0 then copy[k] = n end
    end
    if not ch then ch = {} storage.channels[channel] = ch end
    ch[c.unit] = copy
end

--- receive(channel) -> { [key] = summed count } from every transmitter.
function API.receive(channel)
    current("receive")
    local result = {}
    local ch = storage.channels and storage.channels[channel]
    if not ch then return result end
    for _, values in pairs(ch) do
        for k, v in pairs(values) do result[k] = (result[k] or 0) + v end
    end
    return result
end

-- ---- script.* -------------------------------------------------------------

local script_api = {}

local function check_handler(fname, fn)
    if type(fn) ~= "function" then error("script." .. fname .. ": handler must be a function", 3) end
end

function script_api.on_event(ids, handler)
    check_handler("on_event", handler)
    local c = current("script.on_event")
    if c.mode ~= "setup" then return end   -- registration only happens in setup
    if type(ids) ~= "table" then ids = {ids} end
    for _, id in ipairs(ids) do
        if id == nil then error("script.on_event: unknown event id", 2) end
        events.add_user(id, c.unit, handler)
    end
end

function script_api.on_nth_tick(n, handler)
    check_handler("on_nth_tick", handler)
    local c = current("script.on_nth_tick")
    if c.mode ~= "setup" then return end
    if type(n) ~= "number" or n < 1 then error("script.on_nth_tick: tick must be a positive number", 2) end
    events.add_user_nth(math.floor(n), c.unit, handler)
end

--- Runs once with live data when code is applied (not on load).
function script_api.on_init(handler)
    check_handler("on_init", handler)
    local c = current("script.on_init")
    if c.mode ~= "setup" then return end
    c.init_handlers = c.init_handlers or {}
    table.insert(c.init_handlers, handler)
end

--- Runs during every setup pass (apply and load) – must not change state.
function script_api.on_load(handler)
    check_handler("on_load", handler)
    local c = current("script.on_load")
    if c.mode ~= "setup" then return end
    pcall(handler)
end

setmetatable(script_api, {
    __index = function(_, key)
        error("script." .. tostring(key) .. " is not available in combinator scripts", 2)
    end,
    __newindex = function() error("script is read-only", 2) end,
})
API.script = script_api

-- ---- Standard library ------------------------------------------------------

local STD = {
    "math", "table", "string", "bit32",
    "pairs", "ipairs", "next", "select", "type", "tostring", "tonumber",
    "pcall", "xpcall", "error", "assert",
    "rawget", "rawset", "rawequal", "rawlen", "setmetatable", "getmetatable",
    "table_size", "defines", "remote",
}

local BASE = {}
for _, name in ipairs(STD) do BASE[name] = _G[name] end
BASE.unpack = table.unpack
for k, v in pairs(API) do BASE[k] = v end

-- Values that only exist once the game is running, or that are computed
-- per execution, are resolved on access.
local LAZY_GLOBALS = {game = true, rendering = true, prototypes = true, helpers = true, settings = true}

setmetatable(BASE, {
    __index = function(_, key)
        if key == "red" or key == "green" then
            if not ctx then return EMPTY end
            return read_side(ctx, "input")[key]
        end
        if LAZY_GLOBALS[key] then
            -- nil while registering handlers, for the same reason as `entity`
            if ctx and ctx.inert then return nil end
            return _G[key]
        end
        return nil
    end,
    __newindex = function() error("the shared API table is read-only", 2) end,
})

local ENV_MT = {__index = BASE}

local function fill_env(env, c)
    rawset(env, "tick", c.tick)
    rawset(env, "entity", c.entity)
    rawset(env, "unit_number", c.unit)
    rawset(env, "storage", c.storage)
    rawset(env, "shared", c.shared)
    return env
end

-- ---------------------------------------------------------------------------
-- Compilation
-- ---------------------------------------------------------------------------

local function chunk(record)
    local unit = record.unit_number
    local entry = compiled[unit]
    if entry and entry.code == record.code then return entry.fn, entry.err end
    local fn, err = load("local _ENV = ...; " .. record.code, "=Lua Combinator #" .. unit, "t", {})
    compiled[unit] = {code = record.code, fn = fn, err = err and util.error_string(err) or nil}
    return fn, compiled[unit].err
end

--- Check that code compiles; returns nil or an error message.
function sandbox.check(code)
    local fn, err = load("local _ENV = ...; " .. code, "=code", "t", {})
    if fn then return nil end
    return util.error_string(err)
end

-- ---------------------------------------------------------------------------
-- Public entry points
-- ---------------------------------------------------------------------------

--- Execute a combinator's top-level code with live data.
function sandbox.run(record, tick)
    if not record.code or record.code == "" then return true end
    local fn, err = chunk(record)
    if not fn then
        set_error(record, "run", "Compile: " .. err)
        return false
    end
    local c = new_context(record, tick, "run")
    local ok, run_err = call_with(c, fn, fill_env(setmetatable({}, ENV_MT), c))
    record.stats.runs = (record.stats.runs or 0) + 1
    record.stats.last_run = tick
    if not ok then
        set_error(record, "run", util.error_string(run_err))
        return false
    end
    local applied, out_err = outputs.apply(record, c.outputs)
    if not applied then
        set_error(record, "run", "Output: " .. out_err)
        return false
    end
    clear_error(record)
    return true
end

local function invoke(unit, fn, event_data, kind)
    local record = storage.combinators[unit]
    if not (record and record.entity and record.entity.valid) then return end
    local c = new_context(record, game.tick, "event")
    local env = event_envs[unit]
    if env then fill_env(env, c) end
    local ok, err = call_with(c, fn, event_data)
    record.stats.events = (record.stats.events or 0) + 1
    if not ok then
        set_error(record, "event", (kind == "nth_tick" and "on_nth_tick: " or "on_event: ") .. util.error_string(err))
        return
    end
    if c.touched then
        local applied, out_err = outputs.apply(record, c.outputs)
        if not applied then
            set_error(record, "event", "Output: " .. out_err)
            return
        end
    end
    clear_error(record, "event")
end

events.set_user_invoker(invoke)

--- (Re-)register a combinator's script.on_event / on_nth_tick handlers.
--- mode "apply": also runs script.on_init handlers with live data.
--- mode "load":  side-effect free (safe inside on_load).
function sandbox.setup(record, mode)
    local unit = record.unit_number
    events.remove_unit(unit)
    event_envs[unit] = nil
    if not record.code or record.code == "" then return end
    local fn = chunk(record)
    if not fn then return end

    local c = new_context(record, 0, "setup")
    local env = fill_env(setmetatable({}, ENV_MT), c)
    event_envs[unit] = env
    call_with(c, fn, env)   -- errors are reported by the next real run

    if mode == "apply" and c.init_handlers then
        for _, handler in ipairs(c.init_handlers) do invoke(unit, handler, nil, "init") end
    end
end

--- Forget everything cached for a combinator.
function sandbox.forget(unit)
    compiled[unit] = nil
    event_envs[unit] = nil
    events.remove_unit(unit)
end

sandbox.clear_error = clear_error

--- Names exposed to scripts (for the GUI help text and tests).
function sandbox.api_names()
    local names = {}
    for k in pairs(API) do names[#names + 1] = k end
    table.sort(names)
    return names
end

return sandbox
