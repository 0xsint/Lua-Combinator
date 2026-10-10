-- ===========================================================================
-- control.lua  –  Lua Combinator runtime
-- ===========================================================================
--
-- PLAYER API (available inside every combinator's code block):
-- Full details, examples, and gotchas: see API_REFERENCE.md in this mod's
-- folder.
--
--   tick          (number)  Current game tick.
--   red           (table)   { [signal_name] = count }  Red-wire inputs.
--   green         (table)   { [signal_name] = count }  Green-wire inputs.
--   entity        (LuaEntity) The combinator entity itself.
--   set_output(type, name, count)
--                           Queue an output signal.
--                           type : "item" | "fluid" | "virtual"
--                           name : signal name string (e.g. "iron-plate",
--                                  "water", "signal-A", "signal-red")
--                           count: integer
--   clear_output()          Discards any output signals queued so far this
--                           execution (e.g. to override earlier set_output
--                           calls based on later logic).
--   get_signal(name [, color])
--                           Reads a signal's value. With no color, returns
--                           red+green combined; color is "red" or "green"
--                           to read just that wire. Shorthand for
--                           (red[name] or 0) + (green[name] or 0).
--   get_output_signal(name [, color])
--                           Same as get_signal, but reads the combinator's
--                           OUTPUT wires instead of its input wires: the
--                           live network state as of the start of this
--                           execution (last tick's output, including
--                           anything else feeding that wire), NOT values
--                           queued by set_output calls made so far this
--                           execution — those aren't applied until after
--                           the code finishes running.
--   get_network(color [, side])
--                           Returns the raw LuaCircuitNetwork for a wire,
--                           without needing defines.wire_connector_id.*.
--                           color: "red" | "green". side: "input" (default)
--                           | "output".
--   print(...)              Prints a message to the game chat (all players).
--   dump(...)               Like print(), but tables are pretty-printed
--                           (via inspect()) instead of showing as addresses.
--   log(...)                Writes to the log file (factorio-current.log)
--                           instead of chat; tables are pretty-printed.
--   inspect(value)          Returns a deterministic, human-readable string
--                           for any value (tables included).
--   clamp(value, min, max)  Clamps value into [min, max]. Either bound may
--                           be nil to leave that side unclamped.
--   round(value [, decimals])
--                           Rounds value to the given decimal places
--                           (default 0).
--   storage       (table)   Persistent per-combinator table.  Data survives
--                           across ticks and game loads.
--   math / table / string / pairs / ipairs / type / tonumber / tostring /
--   pcall / xpcall / error / assert / setmetatable / getmetatable /
--   rawget / rawset / rawequal / rawlen / select / next / unpack
--
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- SECTION 1 – Utility
-- ---------------------------------------------------------------------------

--- Recursively find a named child inside a GUI element tree.
local function find_child(element, name)
    if not (element and element.valid) then return nil end
    for _, child in pairs(element.children) do
        if child.name == name then return child end
        local found = find_child(child, name)
        if found then return found end
    end
    return nil
end

--- Convert a pcall/xpcall error value into a deterministic string.
--- Lua's built-in tostring() prints a raw memory address for tables,
--- functions, etc. (e.g. "table: 0x0000018f2a3b4580"), and that address is
--- different on every machine. Combinator code can raise non-string errors
--- via error({...}) or assert(false, {...}), and since the result is stored
--- in `storage` (synced, checksummed game state), using tostring() directly
--- here desyncs the game the moment two peers format the same error
--- differently. serpent is safe because Factorio's build disables address
--- comments for determinism.
local function safe_error_string(err)
    local t = type(err)
    if t == "string" or t == "number" or t == "boolean" or t == "nil" then
        return tostring(err)
    end
    local ok, serialized = pcall(serpent.line, err, {sortkeys = true})
    return ok and serialized or ("<" .. t .. " error value>")
end

--- Format a circuit network's signals into a human-readable string.
local function format_signals(net)
    if not (net and net.signals) then return "(none)" end
    local lines = {}
    for _, sig in pairs(net.signals) do
        table.insert(lines, string.format("[%s] %s = %d",
            sig.signal.type, sig.signal.name, sig.count))
    end
    if #lines == 0 then return "(none)" end
    table.sort(lines)
    return table.concat(lines, "\n")
end

--- Pretty-print a value for debugging. Tables are serialized deterministically
--- (sorted keys, no raw memory addresses) via serpent so the result is safe
--- to compare across machines/players; everything else just uses tostring().
local function inspect(value)
    if type(value) == "table" then
        local ok, serialized = pcall(serpent.block, value, {sortkeys = true, comment = false})
        return ok and serialized or "<unserializable table>"
    end
    return tostring(value)
end

--- Clamp a number into the inclusive [min, max] range. Either bound may be
--- omitted (nil) to leave that side unclamped.
local function clamp(value, min, max)
    value = tonumber(value) or 0
    if min and value < min then return min end
    if max and value > max then return max end
    return value
end

--- Round a number to the given number of decimal places (default 0).
local function round(value, decimals)
    value = tonumber(value) or 0
    local mult = 10 ^ (decimals or 0)
    return math.floor(value * mult + 0.5) / mult
end

--- Write a debug message to the log file (factorio-current.log) rather than
--- game chat. Safe to call from any stage, including on_load. Table
--- arguments are serialized via inspect() instead of printing raw addresses.
local function log_fn(...)
    local parts = {}
    local args = table.pack(...)
    for i = 1, args.n do parts[i] = inspect(args[i]) end
    log(table.concat(parts, "  "))
end

-- ---------------------------------------------------------------------------
-- SECTION 1b – Managed script-event dispatch
-- ---------------------------------------------------------------------------
-- Allows combinator code to call script.on_event / script.on_nth_tick safely.
-- Factorio only supports ONE handler per event per mod, so we keep our own
-- dispatch tables and register a single real Factorio handler per event type.
-- Lua closures are NOT serialisable, so handlers are re-created from user code
-- on every game load via run_setup_pass().

local event_dispatch    = {}   -- [event_id] = { [unit_number] = fn }
local nth_tick_dispatch = {}   -- [n]         = { [unit_number] = fn }
local registered_events = {}   -- [event_id] = true  (real Factorio handler exists)
local registered_nth    = {}   -- [n]        = true

-- The sandbox table used as _ENV when a combinator's script.on_event /
-- script.on_nth_tick handlers were compiled (see run_setup_pass, SECTION 2).
-- Handler closures resolve globals (get_signal, red, green, set_output, …)
-- by looking them up in this SAME table every time they run, so refreshing
-- its fields in place (via populate_runtime, SECTION 2) right before a
-- dispatch makes those handlers see live circuit-network data instead of
-- the inert stand-ins used while merely (re-)registering them.
local combinator_sandboxes = {}   -- [unit_number] = sandbox table

-- Implemented in SECTION 2; forward-declared so the dispatchers below (used
-- by make_script_wrapper, defined earlier in this section) can call them.
local populate_runtime
local apply_outputs

local function dispatch_event(event_id, event_data)
    local handlers = event_dispatch[event_id]
    if not handlers then return end
    for unit_number, fn in pairs(handlers) do
        local cdata = storage.combinators[unit_number]
        if cdata and cdata.entity and cdata.entity.valid then
            local sandbox = combinator_sandboxes[unit_number]
            local pending_outputs = sandbox and populate_runtime(sandbox, cdata.entity, cdata, game.tick)
            local ok, err = pcall(fn, event_data)
            if not ok then cdata.last_error = "Event error: " .. safe_error_string(err) end
            if sandbox then
                cdata.storage = sandbox.storage
                if pending_outputs then
                    apply_outputs(cdata.entity, pending_outputs, cdata.output_enabled ~= false)
                end
            end
        else
            handlers[unit_number] = nil
        end
    end
end

local function dispatch_nth_tick(n, event_data)
    local handlers = nth_tick_dispatch[n]
    if not handlers then return end
    for unit_number, fn in pairs(handlers) do
        local cdata = storage.combinators[unit_number]
        if cdata and cdata.entity and cdata.entity.valid then
            local sandbox = combinator_sandboxes[unit_number]
            local pending_outputs = sandbox and populate_runtime(sandbox, cdata.entity, cdata, game.tick)
            local ok, err = pcall(fn, event_data)
            if not ok then cdata.last_error = "nth_tick error: " .. safe_error_string(err) end
            if sandbox then
                cdata.storage = sandbox.storage
                if pending_outputs then
                    apply_outputs(cdata.entity, pending_outputs, cdata.output_enabled ~= false)
                end
            end
        else
            handlers[unit_number] = nil
        end
    end
end

--- Returns a per-combinator 'script' table exposed inside every sandbox.
local function make_script_wrapper(unit_number)
    local wrapper = {}

    function wrapper.on_event(events_or_id, handler)
        if type(handler) ~= "function" then
            error("script.on_event: handler must be a function", 2)
        end
        local ids = type(events_or_id) == "table" and events_or_id or {events_or_id}
        for _, eid in ipairs(ids) do
            if not registered_events[eid] then
                registered_events[eid] = true
                local eid_cap = eid
                script.on_event(eid_cap, function(e) dispatch_event(eid_cap, e) end)
            end
            if not event_dispatch[eid] then event_dispatch[eid] = {} end
            event_dispatch[eid][unit_number] = handler
        end
    end

    function wrapper.on_nth_tick(n, handler)
        if type(handler) ~= "function" then
            error("script.on_nth_tick: handler must be a function", 2)
        end
        if not registered_nth[n] then
            registered_nth[n] = true
            local n_cap = n
            script.on_nth_tick(n_cap, function(e) dispatch_nth_tick(n_cap, e) end)
        end
        if not nth_tick_dispatch[n] then nth_tick_dispatch[n] = {} end
        nth_tick_dispatch[n][unit_number] = handler
    end

    -- on_init / on_load in combinator context: call the handler immediately
    -- since the setup pass IS the per-load initialisation step.
    function wrapper.on_init(handler)
        if type(handler) == "function" then pcall(handler) end
    end
    function wrapper.on_load(handler)
        if type(handler) == "function" then pcall(handler) end
    end

    setmetatable(wrapper, {
        __index = function(_, key)
            error("script." .. tostring(key) .. " is not available in combinator scripts", 2)
        end,
    })
    return wrapper
end

-- ---------------------------------------------------------------------------
-- SECTION 2 – Execution engine
-- ---------------------------------------------------------------------------

--- Wire-connector ids for each (side, color) combination, so sandboxed code
--- doesn't need to remember the raw defines.wire_connector_id.* names.
local NETWORK_WIRE_IDS = {
    input  = {
        red   = defines.wire_connector_id.combinator_input_red,
        green = defines.wire_connector_id.combinator_input_green,
    },
    output = {
        red   = defines.wire_connector_id.combinator_output_red,
        green = defines.wire_connector_id.combinator_output_green,
    },
}

--- Fill in (or refresh) the entity/circuit-network-dependent parts of a
--- sandbox: red/green inputs, get_signal/get_output_signal/get_network/
--- set_output/clear_output, print/dump, tick, entity, and storage. Used both
--- to populate a brand-new sandbox (the timer-driven execution path,
--- build_sandbox below) and to refresh an EXISTING sandbox's fields in place
--- right before invoking a script.on_event / script.on_nth_tick handler
--- compiled against it (see dispatch_event / dispatch_nth_tick, SECTION 1),
--- so those handlers always see live data instead of the inert stand-ins
--- used while merely (re-)registering them in run_setup_pass.
---@return table pending_outputs  (filled by set_output calls inside the chunk)
function populate_runtime(sandbox, entity, data, tick)
    -- ---- Read circuit-network inputs ----
    local input_red   = {}
    local input_green = {}

    local red_net   = entity.get_circuit_network(defines.wire_connector_id.combinator_input_red)
    local green_net = entity.get_circuit_network(defines.wire_connector_id.combinator_input_green)

    if red_net and red_net.signals then
        for _, sig in pairs(red_net.signals) do
            input_red[sig.signal.name] = sig.count
        end
    end
    if green_net and green_net.signals then
        for _, sig in pairs(green_net.signals) do
            input_green[sig.signal.name] = sig.count
        end
    end

    -- ---- Read circuit-network outputs (as of the start of this execution;
    -- does NOT include set_output calls made so far this execution, since
    -- those are only applied to the combinator's behavior afterwards) ----
    local output_red   = {}
    local output_green = {}

    local out_red_net   = entity.get_circuit_network(defines.wire_connector_id.combinator_output_red)
    local out_green_net = entity.get_circuit_network(defines.wire_connector_id.combinator_output_green)

    if out_red_net and out_red_net.signals then
        for _, sig in pairs(out_red_net.signals) do
            output_red[sig.signal.name] = sig.count
        end
    end
    if out_green_net and out_green_net.signals then
        for _, sig in pairs(out_green_net.signals) do
            output_green[sig.signal.name] = sig.count
        end
    end
    local pending_outputs
    pending_outputs = pending_outputs or {}
    -- ---- Output accumulator ----
    local function set_output(sig_type, sig_name, count)
        if type(sig_type) ~= "string" then
            error("set_output arg #1 (type) must be a string", 2)
        end
        if type(sig_name) ~= "string" then
            error("set_output arg #2 (name) must be a string", 2)
        end
        local n = tonumber(count) or 0
        if n == 0 then return end   -- zero-count signals are a no-op
        local rng = {}
        rng.seed = math.random(1, 429496)
            table.insert(pending_outputs, {
                signal = {type = sig_type, name = sig_name},
                count  = n,
                index = rng.seed,
            })
    end

    -- ---- Print helper (chat visible to all players) ----
    local function print_fn(...)
        local parts = {}
        local args = table.pack(...)
        for i = 1, args.n do parts[i] = tostring(args[i]) end
        game.print(
            table.concat(parts, "  "),
            {r = 0.4, g = 1.0, b = 0.9}
        )
    end

    -- ---- Pretty-print straight to chat (tables rendered via inspect()) ----
    local function dump(...)
        local parts = {}
        local args = table.pack(...)
        for i = 1, args.n do parts[i] = inspect(args[i]) end
        print_fn(table.concat(parts, "  "))
    end

    -- ---- Merged / per-wire signal lookup ----
    -- get_signal(name)        -> red[name] + green[name] (what the combinator
    --                            would see if both wires fed the same input)
    -- get_signal(name, color) -> just that wire's value ("red" or "green")
    local function get_signal(name, color)
        if type(name) ~= "string" then
            error("get_signal arg #1 (name) must be a string", 2)
        end
        if color == nil then
            return (input_red[name] or 0) + (input_green[name] or 0)
        elseif color == "red" then
            return input_red[name] or 0
        elseif color == "green" then
            return input_green[name] or 0
        else
            error("get_signal arg #2 (color) must be \"red\", \"green\", or nil", 2)
        end
    end

    -- ---- Merged / per-wire OUTPUT signal lookup ----
    -- Mirrors get_signal, but reads the combinator's output wires instead
    -- of its input wires (see the note above output_red/output_green).
    -- get_output_signal(name)        -> output_red[name] + output_green[name]
    -- get_output_signal(name, color) -> just that output wire's value
    local function get_output_signal(name, color)
        if type(name) ~= "string" then
            error("get_output_signal arg #1 (name) must be a string", 2)
        end
        if color == nil then
            return (output_red[name] or 0) + (output_green[name] or 0)
        elseif color == "red" then
            return output_red[name] or 0
        elseif color == "green" then
            return output_green[name] or 0
        else
            error("get_output_signal arg #2 (color) must be \"red\", \"green\", or nil", 2)
        end
    end

    -- ---- Direct circuit-network access, without needing to remember the
    -- raw defines.wire_connector_id.* names ----
    -- get_network("red")                 -> input red network
    -- get_network("green", "output")     -> output green network
    local function get_network(color, side)
        side = side or "input"
        local by_side = NETWORK_WIRE_IDS[side]
        if not by_side then
            error("get_network arg #2 (side) must be \"input\" or \"output\"", 2)
        end
        local wire_id = by_side[color]
        if not wire_id then
            error("get_network arg #1 (color) must be \"red\" or \"green\"", 2)
        end
        return entity.get_circuit_network(wire_id)
    end

    -- ---- Cancel any outputs queued so far this execution ----
    local function clear_output()
        log_fn("clearing outputs")
        for i, po in pairs(entity.get_control_behavior().parameters.outputs) do
            log_fn("pending_outputs before removal", pending_outputs)
            log_fn("current output", po)
            entity.get_control_behavior().remove_output(i)
            log_fn("removed output", i)
            pending_outputs[i] = nil
        end
    end

    sandbox.entity            = entity
    sandbox.tick              = tick
    sandbox.red               = input_red
    sandbox.green             = input_green
    sandbox.set_output        = set_output
    sandbox.clear_output      = clear_output
    sandbox.get_signal        = get_signal
    sandbox.get_output_signal = get_output_signal
    sandbox.get_network       = get_network
    sandbox.print             = print_fn
    sandbox.dump              = dump
    -- Persistent per-combinator storage
    sandbox.storage           = data.storage

    return pending_outputs
end

--- Build a sandboxed environment for user code (the timer-driven execution
--- path). Populates the static/always-available parts, then delegates the
--- entity/circuit-network-dependent parts to populate_runtime.
---@return table sandbox
---@return table pending_outputs  (filled by set_output calls inside the chunk)
local function build_sandbox(entity, data, tick)
    local sandbox = {
        -- Safe standard library
        math       = math,
        table      = table,
        string     = string,
        -- Basic Lua builtins
        pairs      = pairs,
        ipairs     = ipairs,
        next       = next,
        select     = select,
        type       = type,
        tostring   = tostring,
        tonumber   = tonumber,
        pcall      = pcall,
        xpcall     = xpcall,
        error      = error,
        assert     = assert,
        rawget     = rawget,
        rawset     = rawset,
        rawequal   = rawequal,
        rawlen     = rawlen,
        setmetatable  = setmetatable,
        getmetatable  = getmetatable,
        unpack     = table.unpack,
        -- Factorio runtime API
        game       = game,
        defines    = defines,
        remote     = remote,
        rendering  = rendering,
        prototypes = prototypes,
        script     = make_script_wrapper(entity.unit_number),
        log        = log_fn,
        inspect    = inspect,
        clamp      = clamp,
        round      = round,
    }
    -- Self-referential _ENV so bare globals resolve in our sandbox
    sandbox._ENV = sandbox

    local pending_outputs = populate_runtime(sandbox, entity, data, tick)
    return sandbox, pending_outputs
end

--- Apply pending outputs to the decider-combinator behaviour.
--- Replaces the whole `parameters` structure in one atomic assignment
--- (clearing it to nil and then using add_condition/add_output leaves a
--- leftover default condition/output from the entity's template behind,
--- which prevents the combinator from ever outputting anything).
function apply_outputs(entity, pending_outputs, enabled)
    local behavior = entity.get_or_create_control_behavior()

    if not enabled or #pending_outputs == 0 then
        behavior.parameters = nil
        return
    end
    behavior.add_condition({
        comparator    = "=",
    })
    for index, po in ipairs(pending_outputs) do
        log_fn("processing pending output", po.signal.name, po.count, po.signal.type, po.index)
        log_fn("signal last tick", po.signal.name, po.count, po.signal.type)
        log_fn("Getting output for pending output", po.signal.name, po.count, po.signal.type, po.index)
        local out = behavior.get_output(index)
        if out then
            if out.signal == nil then
                goto continue
            end
            if out.signal.name == po.signal.name and out.signal.type == po.signal.type then
                out.count = po.count
            end
        end
        ::continue::
        if po.index  then
            behavior.add_output({
                signal                = { type = po.signal.type, name = po.signal.name },
                copy_count_from_input = false,
                constant              = po.count,
            })
        elseif not po.index then
            log_fn("no index for pending output", po.signal.name, po.count, po.signal.type)
            local rng = {}
            rng.seed = math.random(1, 429496)
            po.index = rng.seed
            log_fn("assigned new index for pending output", po.signal.name, po.count, po.signal.type, po.index)
            behavior.add_output({
                signal                = { type = po.signal.type, name = po.signal.name },
                copy_count_from_input = false,
                constant              = po.count,
            })
        end
    end
end

--- Run user code once in a stripped sandbox to (re-)register any
--- script.on_event / script.on_nth_tick handlers declared in the code.
--- Called on game load, code apply, and entity clone.
--- The top-level code itself runs against inert stand-ins (set_output is a
--- no-op, storage is a throwaway table, …) so merely re-registering handlers
--- never touches the entity or persisted storage — importantly, this keeps
--- on_load side-effect-free even for code that unconditionally mutates
--- storage at the top level (Factorio forbids storage changes in on_load).
--- The sandbox itself is kept around (combinator_sandboxes) so that
--- dispatch_event / dispatch_nth_tick can refresh its fields with live data
--- right before actually invoking a registered handler.
local function run_setup_pass(unit_number, data)
    if not (data.code and data.code ~= "") then return end

    -- Clear this combinator's old registrations before re-creating them
    for _, handlers in pairs(event_dispatch)    do handlers[unit_number] = nil end
    for _, handlers in pairs(nth_tick_dispatch) do handlers[unit_number] = nil end

    -- 'game' is nil during on_load; pcall protects against that
    local safe_game
    pcall(function() safe_game = game end)

    local sandbox = {
        math = math, table = table, string = string,
        pairs = pairs, ipairs = ipairs, next = next, select = select,
        type = type, tostring = tostring, tonumber = tonumber,
        pcall = pcall, xpcall = xpcall, error = error, assert = assert,
        rawget = rawget, rawset = rawset, rawequal = rawequal, rawlen = rawlen,
        setmetatable = setmetatable, getmetatable = getmetatable,
        unpack = table.unpack,
        game       = safe_game,
        defines    = defines,
        remote     = remote,
        rendering  = safe_game and rendering  or nil,
        prototypes = safe_game and prototypes or nil,
        script     = make_script_wrapper(unit_number),
        -- Combinator API stubs (no side-effects during setup pass; refreshed
        -- with live data by populate_runtime before real handler dispatch)
        entity        = (data.entity and data.entity.valid) and data.entity or nil,
        tick          = 0,
        red           = {},
        green         = {},
        set_output    = function() end,
        clear_output  = function() end,
        get_signal    = function() return 0 end,
        get_output_signal = function() return 0 end,
        get_network   = function() return nil end,
        print         = function() end,
        dump          = function() end,
        log           = log_fn,
        inspect       = inspect,
        clamp         = clamp,
        round         = round,
        -- Throwaway table, NOT data.storage: top-level code that mutates
        -- storage unconditionally (a documented pattern, see EXAMPLE_CODE)
        -- must not touch real persisted storage here, since this pass also
        -- runs during on_load, where Factorio forbids storage changes.
        storage       = {},
    }
    sandbox._ENV = sandbox

    -- Keep the sandbox reachable so dispatch_event / dispatch_nth_tick can
    -- refresh its fields with live data before invoking a registered handler.
    combinator_sandboxes[unit_number] = sandbox

    local fn = load(data.code, "@lua-combinator-setup#" .. unit_number, "t", sandbox)
    if fn then pcall(fn) end  -- errors during setup pass are silently discarded
end

--- Compile and run one combinator's user code.
local function execute_code(entity, data, tick)
    local sandbox, pending_outputs = build_sandbox(entity, data, tick)

    -- Compile the chunk in the sandbox environment
    local fn, compile_err = load(
        data.code,
        "@lua-combinator#" .. entity.unit_number,
        "t",
        sandbox
    )
    if not fn then
        data.last_error = "Compile: " .. safe_error_string(compile_err)
        return
    end

    -- Run with pcall so errors don't halt the game
    local ok, run_err = pcall(fn)
    if not ok then
        data.last_error = "Runtime: " .. safe_error_string(run_err)
        return
    end

    -- Persist storage mutations back
    data.storage   = sandbox.storage
    data.last_error = nil

    apply_outputs(entity, pending_outputs, data.output_enabled ~= false)
end

-- ---------------------------------------------------------------------------
-- SECTION 3 – Global state initialisation
-- ---------------------------------------------------------------------------

local function init_globals()
    -- storage.combinators[unit_number] = {
    --     entity         = LuaEntity,
    --     code           = string,
    --     interval       = uint,
    --     storage        = table,
    --     last_error     = string|nil,
    --     output_enabled = bool,
    --     run_on_timer   = bool,
    -- }
    storage.combinators = storage.combinators or {}
    storage.open_guis   = storage.open_guis   or {}  -- [player_index] = unit_number
end

script.on_init(init_globals)
script.on_configuration_changed(function()
    init_globals()
    -- Validate entity references survive a reload
    for unit_number, data in pairs(storage.combinators) do
        if not (data.entity and data.entity.valid) then
            storage.combinators[unit_number] = nil
        end
        -- Ensure storage table exists (migration from older versions)
        data.storage = data.storage or {}
        -- Defaults for fields added in later versions
        if data.output_enabled == nil then data.output_enabled = true end
        if data.run_on_timer   == nil then data.run_on_timer   = true end
    end
    -- Re-register script event handlers after config change
    for unit_number, cdata in pairs(storage.combinators) do
        run_setup_pass(unit_number, cdata)
    end
end)

-- Re-register event handlers on every game load (closures don't survive saves)
script.on_load(function()
    for unit_number, cdata in pairs(storage.combinators) do
        run_setup_pass(unit_number, cdata)
    end
end)

-- ---------------------------------------------------------------------------
-- SECTION 4 – Entity registration / deregistration
-- ---------------------------------------------------------------------------

local function register_combinator(entity)
    storage.combinators[entity.unit_number] = {
        entity         = entity,
        code           = "",
        interval       = 20,
        storage        = {},
        last_error     = nil,
        output_enabled = true,
        run_on_timer   = true,
    }
end

local function unregister_combinator(entity)
    storage.combinators[entity.unit_number] = nil
    combinator_sandboxes[entity.unit_number] = nil
    for _, handlers in pairs(event_dispatch)    do handlers[entity.unit_number] = nil end
    for _, handlers in pairs(nth_tick_dispatch) do handlers[entity.unit_number] = nil end
end

-- ---- Placement ----
local NAME_FILTER = {{filter = "name", name = "lua-combinator"}}

script.on_event(defines.events.on_built_entity,       function(e) register_combinator(e.entity) end, NAME_FILTER)
script.on_event(defines.events.on_robot_built_entity, function(e) register_combinator(e.entity) end, NAME_FILTER)

script.on_event(defines.events.script_raised_built, function(e)
    if e.entity.name == "lua-combinator" then register_combinator(e.entity) end
end)
script.on_event(defines.events.script_raised_revive, function(e)
    if e.entity.name == "lua-combinator" then register_combinator(e.entity) end
end)

-- Clone: copy code/interval from source
script.on_event(defines.events.on_entity_cloned, function(e)
    if e.destination.name ~= "lua-combinator" then return end
    register_combinator(e.destination)
    local src = storage.combinators[e.source.unit_number]
    if src then
        local dst = storage.combinators[e.destination.unit_number]
        dst.code           = src.code
        dst.interval       = src.interval
        dst.output_enabled = src.output_enabled
        dst.run_on_timer   = src.run_on_timer
        -- storage is intentionally NOT copied so each clone starts fresh
        run_setup_pass(e.destination.unit_number, dst)
    end
end)

-- ---- Removal ----
script.on_event(defines.events.on_player_mined_entity, function(e)
    if e.entity.name == "lua-combinator" then unregister_combinator(e.entity) end
end, NAME_FILTER)

script.on_event(defines.events.on_robot_mined_entity, function(e)
    if e.entity.name == "lua-combinator" then unregister_combinator(e.entity) end
end, NAME_FILTER)

script.on_event(defines.events.on_entity_died, function(e)
    if e.entity.name == "lua-combinator" then unregister_combinator(e.entity) end
end, NAME_FILTER)

script.on_event(defines.events.script_raised_destroy, function(e)
    if e.entity.name == "lua-combinator" then unregister_combinator(e.entity) end
end)

-- ---------------------------------------------------------------------------
-- SECTION 5 – Main tick handler
-- ---------------------------------------------------------------------------

script.on_event(defines.events.on_tick, function(event)
    local tick = event.tick

    -- ---- Execute combinator code ----
    local to_remove = {}
    for unit_number, data in pairs(storage.combinators) do
        local entity = data.entity
        if not (entity and entity.valid) then
            table.insert(to_remove, unit_number)
        else
            local interval = data.interval or 20
            if data.code and data.code ~= "" and data.run_on_timer ~= false and tick % interval == 0 then
                execute_code(entity, data, tick)
            end
        end
    end
    for _, unit_number in ipairs(to_remove) do
        storage.combinators[unit_number] = nil
    end

    -- ---- Refresh error labels in open GUIs every 20 ticks ----
    if tick % 20 == 0 then
        for player_index, unit_number in pairs(storage.open_guis) do
            local player = game.players[player_index]
            if player and player.valid then
                local frame = player.gui.screen["lua-combinator-gui"]
                if frame and frame.valid then
                    local data = storage.combinators[unit_number]
                    if data then
                        -- Refresh error label
                        local lbl = find_child(frame, "lua-combinator-error")
                        if lbl then
                            lbl.caption = data.last_error
                                and ("⚠  " .. data.last_error)
                                or  ""
                        end
                        -- Refresh signal monitor
                        local entity = data.entity
                        if entity and entity.valid then
                            local red_box   = find_child(frame, "lua-combinator-red-signals")
                            local green_box = find_child(frame, "lua-combinator-green-signals")
                            if red_box then
                                red_box.text = format_signals(
                                    entity.get_circuit_network(defines.wire_connector_id.combinator_input_red)) .. "\n OUTPUTS \n" .. format_signals(
                                    entity.get_circuit_network(defines.wire_connector_id.combinator_output_red))
                            end
                            if green_box then
                                green_box.text = format_signals(
                                    entity.get_circuit_network(defines.wire_connector_id.combinator_input_green)) .. "\n OUTPUTS \n" .. format_signals(
                                    entity.get_circuit_network(defines.wire_connector_id.combinator_output_green))
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- SECTION 6 – GUI
-- ---------------------------------------------------------------------------

local GUI_NAME = "lua-combinator-gui"

-- Default example shown when a newly placed combinator is first opened
local EXAMPLE_CODE = [[-- ============================================================
-- LUA COMBINATOR – quick reference
-- Full reference with every function and more examples: API_REFERENCE.md
-- ============================================================
-- INPUTS  (read-only tables, populated each tick from wires)
--   red   { [signal_name] = count }   signals on the red   input wire
--   green { [signal_name] = count }   signals on the green input wire
--   tick  (number)                    current game tick
--   get_signal(name [, color])        red+green merged, or just one wire
--
-- OUTPUTS
--   set_output(type, name, count)
--       type : "item" | "fluid" | "virtual"
--       name : e.g. "iron-plate", "water", "signal-A"
--       count: integer (0 is silently ignored)
--   clear_output()      discard everything queued so far this execution
--   get_output_signal(name [, color])
--       reads the OUTPUT wires instead of the input wires (last tick's
--       output network state, not this execution's pending set_output calls)
--
-- NETWORKS
--   get_network(color [, side])   raw LuaCircuitNetwork, no defines needed
--       color: "red" | "green"    side: "input" (default) | "output"
--
-- UTILITIES
--   print(...)          send a chat message (all players)
--   dump(...)           like print(), but pretty-prints tables
--   log(...)            write to factorio-current.log (not chat)
--   inspect(value)       -> human-readable string for any value
--   clamp(value, min, max)   round(value [, decimals])
--   storage  {}         persistent per-combinator table (survives reloads)
--
-- FACTORIO API  (full runtime access)
--   game        – LuaGameScript  (game.players, game.surfaces, …)
--   defines     – all enums      (defines.events, defines.direction, …)
--   remote      – mod interfaces
--   rendering   – in-world drawing
--   prototypes  – prototype data
--   entity      – this combinator’s LuaEntity (navigate output network, etc.)
--
-- EVENTS  (register once; re-registered automatically on every load)
--   script.on_event(defines.events.XYZ, function(e) … end)
--   script.on_nth_tick(n, function(e) … end)
--   script.on_init(fn)   script.on_load(fn)
--
-- TIMER TOGGLE  (settings row in this GUI)
--   "Timer" checked   → code runs every N ticks automatically
--   "Timer" unchecked → code runs ONLY via registered event handlers
--
-- Standard Lua: math  table  string  pairs  ipairs  pcall  …
-- ============================================================

-- ── Example 1: pass-through ──────────────────────────────────
-- Forward the iron-plate count from the red wire to the output.
-- local iron = red["iron-plate"] or 0
-- if iron > 0 then
--     set_output("item", "iron-plate", iron)
-- end

-- ── Example 2: virtual counter ───────────────────────────────
-- Increment a persistent counter every execution and output it.
-- storage.n = (storage.n or 0) + 1
-- set_output("virtual", "signal-C", storage.n)

-- ── Example 2b: Lua Combinator virtual signal ────────────────
-- Send this mod's signal to a connected combinator. There, read it with:
-- local enabled = get_signal("signal-lua-combinator") > 0
-- set_output("virtual", "signal-lua-combinator", 1)

-- ── Example 3: event-driven (uncheck Timer in settings) ──────
-- Announce when any player joins the game.
-- script.on_event(defines.events.on_player_joined_game, function(e)
--     local name = game.players[e.player_index].name
--     print("Welcome, " .. name .. "!")
--     set_output("virtual", "signal-green", 1)
-- end)

-- ── Example 4: nth-tick polling (uncheck Timer) ───────────────
-- Check rocket launches every 5 seconds (300 ticks).
-- script.on_nth_tick(300, function(e)
--     local force = game.forces["player"]
--     set_output("virtual", "signal-R", force.rockets_launched)
-- end)

-- ── Example 5: merged-signal threshold with debug logging ────
-- Average the red+green iron-plate count, clamp it, and log it.
-- local iron = clamp(get_signal("iron-plate"), 0, 1000)
-- log("iron-plate combined:", iron)
-- set_output("item", "iron-plate", iron)

-- ── Active code below (remove comments to enable) ────────────
local iron = red["iron-plate"] or 0
if iron > 0 then
    set_output("item", "iron-plate", iron)
end
]]

--- Open (or re-open) the code editor GUI for one player.
local function open_gui(player, entity)
    -- Destroy any existing instance first
    if player.gui.screen[GUI_NAME] then
        player.gui.screen[GUI_NAME].destroy()
    end

    local data = storage.combinators[entity.unit_number]
    if not data then return end

    storage.open_guis[player.index] = entity.unit_number

    -- ---- Root frame ----
    local frame = player.gui.screen.add{
        type      = "frame",
        name      = GUI_NAME,
        caption   = {"lua-combinator.gui-title", entity.unit_number},
        direction = "vertical",
    }
    frame.auto_center         = true
    frame.style.minimal_width = 540

    -- ---- API hint ----
    local hint = frame.add{
        type    = "label",
        caption = "tick · red{} · green{} · set_output() · get_signal() · get_output_signal() · get_network() · storage{} · print() · dump() · log() · inspect() · clamp() · round() · game · defines · remote · rendering · prototypes",
        tooltip = "Full API reference: API_REFERENCE.md (in this mod's folder)",
    }
    hint.style.font_color     = {r = 0.55, g = 0.85, b = 1.0}
    hint.style.bottom_padding = 4
    hint.style.single_line    = false
    hint.style.maximal_width  = 524

    -- ---- Code text-box ----
    local code_box = frame.add{
        type = "text-box",
        name = "lua-combinator-code",
        text = data.code ~= "" and data.code or EXAMPLE_CODE,
    }
    code_box.style.width     = 524
    code_box.style.height    = 340
    code_box.word_wrap        = false

    -- ---- Settings row ----
    local settings = frame.add{type = "flow", direction = "horizontal"}
    settings.style.vertical_align   = "center"
    settings.style.horizontal_spacing = 6
    settings.style.top_padding       = 4

    settings.add{
        type    = "checkbox",
        name    = "lua-combinator-run-on-timer",
        caption = "Timer",
        state   = data.run_on_timer ~= false,
        tooltip = "When enabled the code runs automatically every N ticks.\nWhen disabled it only runs via script.on_event / script.on_nth_tick handlers.",
    }
    settings.add{type = "label", caption = "every"}

    local interval_field = settings.add{
        type             = "textfield",
        name             = "lua-combinator-interval",
        text             = tostring(data.interval or 20),
        numeric          = true,
        allow_negative   = false,
        allow_decimal    = false,
        lose_focus_on_confirm = true,
    }
    interval_field.style.width = 64

    settings.add{type = "label", caption = "ticks"}
    settings.add{
        type    = "checkbox",
        name    = "lua-combinator-output-enabled",
        caption = "enabled",
        state   = data.output_enabled ~= false,
        tooltip = "When unchecked the combinator emits no signals on its output wires",
    }

    -- Spacer
    local spacer = settings.add{type = "empty-widget"}
    spacer.style.horizontally_stretchable = true

    -- Run-Now button
    settings.add{
        type    = "button",
        name    = "lua-combinator-run-now",
        caption = "▶  Run Now",
        tooltip = "Execute code immediately (ignore interval)",
        style   = "green_button",
    }

    -- ---- Signal monitor ----
    local sig_header = frame.add{type = "label", caption = "Live Signals  (refreshes every 20 ticks)"}
    sig_header.style.font_color  = {r = 0.6, g = 0.6, b = 0.6}
    sig_header.style.top_padding = 6

    local sig_flow = frame.add{type = "flow", direction = "horizontal"}
    sig_flow.style.horizontal_spacing = 6

    -- Red wire column
    local red_col = sig_flow.add{type = "flow", direction = "vertical"}
    local red_hdr = red_col.add{type = "label", caption = "● Red wire"}
    red_hdr.style.font_color = {r = 1.0, g = 0.3, b = 0.3}
    local red_box = red_col.add{
        type      = "text-box",
        name      = "lua-combinator-red-signals",
        text      = format_signals(entity.get_circuit_network(defines.wire_connector_id.combinator_input_red)) .. "\n OUTPUTS \n" .. format_signals(entity.get_circuit_network(defines.wire_connector_id.combinator_output_red)),
    }
    red_box.read_only       = true
    red_box.style.width     = 257
    red_box.style.height    = 110

    -- Green wire column
    local green_col = sig_flow.add{type = "flow", direction = "vertical"}
    local green_hdr = green_col.add{type = "label", caption = "● Green wire"}
    green_hdr.style.font_color = {r = 0.2, g = 1.0, b = 0.35}
    local green_box = green_col.add{
        type      = "text-box",
        name      = "lua-combinator-green-signals",
        text      = format_signals(entity.get_circuit_network(defines.wire_connector_id.combinator_input_green)) .. "\n OUTPUTS \n" .. format_signals(entity.get_circuit_network(defines.wire_connector_id.combinator_output_green)),
    }
    green_box.read_only       = true
    green_box.style.width     = 257
    green_box.style.height    = 110

    -- ---- Error label ----
    local error_label = frame.add{
        type    = "label",
        name    = "lua-combinator-error",
        caption = data.last_error and ("⚠  " .. data.last_error) or "",
    }
    error_label.style.font_color    = {r = 1.0, g = 0.30, b = 0.30}
    error_label.style.single_line   = false
    error_label.style.maximal_width = 524
    error_label.style.top_padding   = 2

    -- ---- Button row ----
    local buttons = frame.add{type = "flow", direction = "horizontal"}
    buttons.style.top_padding = 4
    buttons.style.horizontal_spacing = 6

    buttons.add{
        type    = "button",
        name    = "lua-combinator-apply",
        caption = "✔  Apply",
        style   = "confirm_button",
        tooltip = "Save the code and interval; code runs on next scheduled tick",
    }

    buttons.add{
        type    = "button",
        name    = "lua-combinator-clear",
        caption = "✖  Clear Output",
        tooltip = "Remove all output signals from this combinator",
    }

    -- Spacer
    local spacer2 = buttons.add{type = "empty-widget"}
    spacer2.style.horizontally_stretchable = true

    buttons.add{
        type    = "button",
        name    = "lua-combinator-close",
        caption = "Close",
        style   = "back_button",
    }

    -- Setting player.opened makes Factorio fire on_gui_closed when the
    -- player presses E, keeping storage.open_guis consistent in MP.
    player.opened = frame
end

--- Helper: save code + interval from the GUI to global state.
local function save_gui_data(player, frame, unit_number)
    local data = storage.combinators[unit_number]
    if not data then return end

    local code_box       = find_child(frame, "lua-combinator-code")
    local interval_field = find_child(frame, "lua-combinator-interval")

    if code_box       then data.code     = code_box.text end
    if interval_field then
        data.interval = math.max(1, tonumber(interval_field.text) or 1)
    end
    local output_cb  = find_child(frame, "lua-combinator-output-enabled")
    if output_cb then data.output_enabled = output_cb.state end
    local timer_cb = find_child(frame, "lua-combinator-run-on-timer")
    if timer_cb then data.run_on_timer = timer_cb.state end
    data.last_error = nil

    -- Re-register script event handlers for the (possibly changed) code
    run_setup_pass(unit_number, data)

    -- Clear the displayed error
    local lbl = find_child(frame, "lua-combinator-error")
    if lbl then lbl.caption = "" end
end

-- ---- Intercept entity-open event ----------------------------------------
script.on_event(defines.events.on_gui_opened, function(event)
    if not (event.entity and event.entity.valid) then return end
    if event.entity.name ~= "lua-combinator" then return end

    local player = game.players[event.player_index]
    player.opened = nil  -- suppress the default constant-combinator GUI
    open_gui(player, event.entity)
end)

-- ---- Button clicks -------------------------------------------------------
script.on_event(defines.events.on_gui_click, function(event)
    local el = event.element
    if not (el and el.valid) then return end

    local player      = game.players[event.player_index]
    local frame       = player.gui.screen[GUI_NAME]
    local unit_number = storage.open_guis[player.index]

    -- ---- Apply ----
    if el.name == "lua-combinator-apply" then
        if not (frame and frame.valid and unit_number) then return end
        save_gui_data(player, frame, unit_number)
        -- Run immediately so entity is used right away (no tick wait)
        local data = storage.combinators[unit_number]
        if data and data.entity and data.entity.valid and data.code ~= "" then
            execute_code(data.entity, data, game.tick)
            local lbl = find_child(frame, "lua-combinator-error")
            if lbl then
                lbl.caption = data.last_error
                    and ("⚠  " .. data.last_error)
                    or  "✔  OK"
            end
        end
        player.print(
            {"lua-combinator.applied"},
            {r = 0.4, g = 1.0, b = 0.4}
        )

    -- ---- Run Now ----
    elseif el.name == "lua-combinator-run-now" then
        if not (frame and frame.valid and unit_number) then return end
        -- First save whatever is currently in the text-box
        save_gui_data(player, frame, unit_number)
        local data = storage.combinators[unit_number]
        if data and data.entity and data.entity.valid and data.code ~= "" then
            execute_code(data.entity, data, game.tick)
            -- Reflect any new error immediately
            local lbl = find_child(frame, "lua-combinator-error")
            if lbl then
                lbl.caption = data.last_error
                    and ("⚠  " .. data.last_error)
                    or  "✔  OK"
            end
        end

    -- ---- Clear Output ----
    elseif el.name == "lua-combinator-clear" then
        if not unit_number then return end
        local data = storage.combinators[unit_number]
        if data and data.entity and data.entity.valid then
            data.entity.get_or_create_control_behavior().parameters = nil
            player.print({"lua-combinator.cleared"}, {r = 0.8, g = 0.8, b = 0.8})
        end

    -- ---- Close ----
    elseif el.name == "lua-combinator-close" then
        if frame and frame.valid then frame.destroy() end
        storage.open_guis[player.index] = nil
    end
end)

-- Clean up tracking when the frame is closed via the [X] button
script.on_event(defines.events.on_gui_closed, function(event)
    if event.element and event.element.valid and event.element.name == GUI_NAME then
        storage.open_guis[event.player_index] = nil
    end
end)

-- Checkboxes that apply immediately without needing Apply
script.on_event(defines.events.on_gui_checked_state_changed, function(event)
    local el = event.element
    if not (el and el.valid) then return end

    local unit_number = storage.open_guis[event.player_index]
    if not unit_number then return end
    local data = storage.combinators[unit_number]
    if not data then return end

    if el.name == "lua-combinator-output-enabled" then
        data.output_enabled = el.state
        if not el.state and data.entity and data.entity.valid then
            data.entity.get_or_create_control_behavior().parameters = nil
        end

    elseif el.name == "lua-combinator-run-on-timer" then
        data.run_on_timer = el.state
    end
end)
