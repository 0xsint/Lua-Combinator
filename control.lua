-- ===========================================================================
-- control.lua  –  Lua Combinator runtime
-- ===========================================================================
--
-- PLAYER API (available inside every combinator's code block):
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
--   print(...)              Prints a message to the game chat (all players).
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

local function dispatch_event(event_id, event_data)
    local handlers = event_dispatch[event_id]
    if not handlers then return end
    for unit_number, fn in pairs(handlers) do
        local cdata = storage.combinators[unit_number]
        if cdata and cdata.entity and cdata.entity.valid then
            local ok, err = pcall(fn, event_data)
            if not ok then cdata.last_error = "Event error: " .. safe_error_string(err) end
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
            local ok, err = pcall(fn, event_data)
            if not ok then cdata.last_error = "nth_tick error: " .. safe_error_string(err) end
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

--- Build a sandboxed environment for user code.
---@return table sandbox
---@return table pending_outputs  (filled by set_output calls inside the chunk)
local function build_sandbox(entity, data, tick)
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

    -- ---- Output accumulator ----
    local pending_outputs = {}

    local function set_output(sig_type, sig_name, count)
        if type(sig_type) ~= "string" then
            error("set_output arg #1 (type) must be a string", 2)
        end
        if type(sig_name) ~= "string" then
            error("set_output arg #2 (name) must be a string", 2)
        end
        local n = math.floor(tonumber(count) or 0)
        if n == 0 then return end   -- zero-count signals are a no-op
        table.insert(pending_outputs, {
            signal = {type = sig_type, name = sig_name},
            count  = n,
        })
    end

    -- ---- Print helper (chat visible to all players) ----
    local unit_str = tostring(entity.unit_number)
    local function print_fn(...)
        local parts = {}
        local args = table.pack(...)
        for i = 1, args.n do parts[i] = tostring(args[i]) end
        game.print(
            table.concat(parts, "  "),
            {r = 0.4, g = 1.0, b = 0.9}
        )
    end

    -- ---- Assemble sandbox ----
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
        -- Lua Combinator API
        entity     = entity,
        tick       = tick,
        red        = input_red,
        green      = input_green,
        set_output = set_output,
        print      = print_fn,
        -- Persistent per-combinator storage
        storage    = data.storage,
    }
    -- Self-referential _ENV so bare globals resolve in our sandbox
    sandbox._ENV = sandbox

    return sandbox, pending_outputs
end

--- Apply pending outputs to the decider-combinator behaviour.
--- Clears any previous state, sets an always-true condition, then adds
--- each output individually using add_condition / add_output.
local function apply_outputs(entity, pending_outputs, enabled)
    local behavior = entity.get_or_create_control_behavior()

    -- Always clear first so stale signals don't persist
    behavior.parameters = nil

    if not enabled or #pending_outputs == 0 then return end

    -- Always-true condition: blank signal (value 0) = constant 0 → 0 = 0
    -- No entity emits a blank/nameless signal, so this is permanently true.
    behavior.add_condition({ comparator = "=" })

    -- Add each output as a fixed constant value
    for _, sig in ipairs(pending_outputs) do
        behavior.add_output({
            signal               = { type = sig.signal.type, name = sig.signal.name },
            copy_count_from_input = false,
            constant             = sig.count,
        })
    end
end

--- Run user code once in a stripped sandbox to (re-)register any
--- script.on_event / script.on_nth_tick handlers declared in the code.
--- Called on game load, code apply, and entity clone.
--- set_output is a no-op; nothing is written to the entity.
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
        -- Combinator API stubs (no side-effects during setup pass)
        entity     = (data.entity and data.entity.valid) and data.entity or nil,
        tick       = 0,
        red        = {},
        green      = {},
        set_output = function() end,
        print      = function() end,
        storage    = data.storage or {},
    }
    sandbox._ENV = sandbox

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
                                    entity.get_circuit_network(defines.wire_connector_id.combinator_input_red))
                            end
                            if green_box then
                                green_box.text = format_signals(
                                    entity.get_circuit_network(defines.wire_connector_id.combinator_input_green))
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
-- ============================================================
-- INPUTS  (read-only tables, populated each tick from wires)
--   red   { [signal_name] = count }   signals on the red   input wire
--   green { [signal_name] = count }   signals on the green input wire
--   tick  (number)                    current game tick
--
-- OUTPUTS
--   set_output(type, name, count)
--       type : "item" | "fluid" | "virtual"
--       name : e.g. "iron-plate", "water", "signal-A"
--       count: integer (0 is silently ignored)
--
-- UTILITIES
--   print(...)          send a chat message (all players)
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
        caption = "tick  ·  red{}  ·  green{}  ·  set_output(type,name,count)  ·  storage{}  ·  print()  ·  game  ·  defines  ·  remote  ·  rendering  ·  prototypes",
    }
    hint.style.font_color     = {r = 0.55, g = 0.85, b = 1.0}
    hint.style.bottom_padding = 4

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
        text      = format_signals(entity.get_circuit_network(defines.wire_connector_id.combinator_input_red)),
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
        text      = format_signals(entity.get_circuit_network(defines.wire_connector_id.combinator_input_green)),
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
