-- ===========================================================================
-- tests/run_tests.lua  –  Headless tests for the Lua Combinator runtime
-- ===========================================================================
-- Run from the repository root with any Lua 5.2 interpreter:
--     lua5.2 tests/run_tests.lua
-- or without a system Lua:   python3 tests/run.py   (uses the `lupa` package)
-- ===========================================================================

package.path = "./?.lua;" .. package.path
local mock = require("tests.mock")
require("control")
mock.lifecycle.init()

local api = mock.interfaces["lua-combinator"]
local E = defines.events

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. name .. "\n      " .. tostring(err))
    end
end

local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local function build(code, opts)
    local e = mock.make_combinator()
    mock.raise("on_built_entity", {entity = e})
    if code then
        local o = {}
        for k, v in pairs(opts or {}) do o[k] = v end
        api.set_code(e.unit_number, code, o)
    end
    return e
end

local function record(e) return storage.combinators[e.unit_number] end

-- ---------------------------------------------------------------------------

test("basic output via set_output and out", function()
    local e = build([[
        set_output("virtual", "signal-A", 5)
        out("iron-plate", 7.9)
        out("water", 3)
    ]])
    local o = mock.outputs_of(e)
    eq(o["virtual/signal-A"], 5)
    eq(o["item/iron-plate"], 7, "floored")
    eq(o["fluid/water"], 3)
    eq(record(e).last_error, nil)
end)

test("outputs are replaced, not accumulated, between runs", function()
    local e = build([[ storage.n = (storage.n or 0) + 1; set_output("virtual", "signal-N", storage.n) ]],
                    {interval = 1})
    mock.tick(5)
    local o = mock.outputs_of(e)
    local n = 0
    for _ in pairs(o) do n = n + 1 end
    eq(n, 1, "one output")
    eq(o["virtual/signal-N"], record(e).storage.n)
end)

test("unchanged outputs are not rewritten", function()
    local e = build([[ set_output("virtual", "signal-A", 1) ]], {interval = 1})
    local before = e.param_writes
    mock.tick(30)
    eq(e.param_writes, before, "no writes for identical output")
end)

test("SignalID table form", function()
    local e = build([[
        set_output({type = "item", name = "copper-plate", quality = "rare"}, 4)
        add_output({name = "signal-A"}, 2)
        add_output({name = "signal-A"}, 2)
    ]])
    local o = mock.outputs_of(e)
    eq(o["item/copper-plate@rare"], 4)
    eq(o["virtual/signal-A"], 4)
    eq(record(e).last_error, nil)
end)

test("set_output 0 removes, add_output accumulates, clear_output clears", function()
    local e = build([[
        set_output("virtual", "signal-A", 1)
        set_output("virtual", "signal-A", 0)
        add_output("virtual", "signal-B", 2)
        add_output("virtual", "signal-B", 3)
        set_output("virtual", "signal-C", 9)
        clear_output()
        add_output("virtual", "signal-D", 4)
        add_output("virtual", "signal-D", 1)
    ]])
    local o = mock.outputs_of(e)
    eq(o["virtual/signal-A"], nil)
    eq(o["virtual/signal-B"], nil)
    eq(o["virtual/signal-C"], nil)
    eq(o["virtual/signal-D"], 5)
end)

test("inputs: red/green tables, get_signal, quality keys, signals()", function()
    local e = build()
    e.inputs.red = {mock.sig("iron-plate", 10), mock.sig("iron-plate", 3, "item", "rare"), mock.sig("signal-A", 1, "virtual")}
    e.inputs.green = {mock.sig("iron-plate", 5)}
    api.set_code(e.unit_number, [[
        set_output("virtual", "signal-R", red["iron-plate"])
        set_output("virtual", "signal-G", green["iron-plate"])
        set_output("virtual", "signal-S", get_signal("iron-plate"))
        set_output("virtual", "signal-Q", get_signal("iron-plate@rare", "red"))
        set_output("virtual", "signal-N", #signals())
        set_output("virtual", "signal-M", #signals("red"))
    ]])
    local o = mock.outputs_of(e)
    eq(o["virtual/signal-R"], 10)
    eq(o["virtual/signal-G"], 5)
    eq(o["virtual/signal-S"], 15)
    eq(o["virtual/signal-Q"], 3)
    eq(o["virtual/signal-N"], 3, "merged list")
    eq(o["virtual/signal-M"], 3)
end)

test("forward with filter and quality outputs", function()
    local e = build()
    e.inputs.red = {mock.sig("iron-plate", 10), mock.sig("copper-plate", 300), mock.sig("iron-plate", 7, "item", "rare")}
    api.set_code(e.unit_number, [[
        forward("red", function(s) if s.count >= 7 then return s.count * 2 end end)
    ]])
    local o = mock.outputs_of(e)
    eq(o["item/iron-plate"], 20)
    eq(o["item/copper-plate"], 600)
    eq(o["item/iron-plate@rare"], 14)
end)

test("invalid signals produce errors with line numbers", function()
    local e = build("local x = 1\nset_output('item', 'bogus-thing', 1)")
    local err = record(e).last_error
    assert(err and err:find("Lua Combinator #%d+:2:") and err:find("bogus%-thing"), tostring(err))
    local e2 = build("set_output('virtual', 'signal-everything', 1)")
    assert(record(e2).last_error:find("wildcard"), record(e2).last_error)
end)

test("compile errors are reported and cleared after a fix", function()
    local e = build("this is not lua")
    assert(record(e).last_error:find("^Compile:"), record(e).last_error)
    api.set_code(e.unit_number, "out('signal-A', 1)")
    eq(record(e).last_error, nil)
end)

test("globals do not leak between runs", function()
    local e = build([[
        if leaked then set_output("virtual", "signal-L", 1) else set_output("virtual", "signal-F", 1) end
        leaked = true
    ]], {interval = 1})
    mock.tick(3)
    local o = mock.outputs_of(e)
    eq(o["virtual/signal-L"], nil)
    eq(o["virtual/signal-F"], 1)
end)

test("scheduler runs on multiples of the interval only", function()
    local e = build([[ storage.ticks = storage.ticks or {}; table.insert(storage.ticks, tick) ]], {interval = 7})
    local start = #record(e).storage.ticks   -- the run triggered by set_code
    mock.tick(30)
    local ticks = record(e).storage.ticks
    for i = start + 1, #ticks do eq(ticks[i] % 7, 0, "aligned") end
    assert(#ticks - start >= 4, "ran " .. (#ticks - start) .. " times")
end)

test("timer off: code only runs through handlers", function()
    local e = build([[
        storage.top = (storage.top or 0) + 1
        script.on_nth_tick(5, function() storage.nth = (storage.nth or 0) + 1; out("signal-N", storage.nth) end)
    ]], {run_on_timer = false})
    local top = record(e).storage.top
    mock.tick(20)
    eq(record(e).storage.top, top, "top-level not re-run")
    assert((record(e).storage.nth or 0) >= 4, "nth ran")
    eq(mock.outputs_of(e)["virtual/signal-N"], record(e).storage.nth)
end)

test("event handlers edit the current outputs", function()
    local e = build([[
        set_output("virtual", "signal-A", 1)
        script.on_event(defines.events.on_console_chat, function(ev)
            set_output("virtual", "signal-B", tonumber(ev.message))
        end)
    ]], {run_on_timer = false})
    mock.raise("on_console_chat", {message = "42"})
    local o = mock.outputs_of(e)
    eq(o["virtual/signal-A"], 1, "kept")
    eq(o["virtual/signal-B"], 42, "added")
end)

test("scripts can listen to on_tick without breaking the scheduler", function()
    local e = build([[
        script.on_event(defines.events.on_tick, function() storage.t = (storage.t or 0) + 1 end)
        storage.runs = (storage.runs or 0) + 1
    ]], {interval = 2})
    local runs = record(e).storage.runs
    mock.tick(10)
    assert(record(e).storage.t >= 10, "user on_tick ran")
    assert(record(e).storage.runs >= runs + 5, "scheduler still runs")
end)

test("script.on_init runs once on apply with live storage", function()
    local e = build([[ script.on_init(function() storage.inited = (storage.inited or 0) + 1 end) ]],
                    {run_on_timer = false})
    eq(record(e).storage.inited, 1)
end)

test("reload rebuilds identical event registrations and keeps working", function()
    local e = build([[
        script.on_event(defines.events.on_research_finished, function() storage.r = (storage.r or 0) + 1 end)
    ]], {run_on_timer = false})
    local before = mock.registrations()
    local storage_before = serpent.line(storage)
    mock.reload()
    eq(mock.registrations(), before, "registrations")
    eq(serpent.line(storage), storage_before, "on_load must not touch storage")
    api = mock.interfaces["lua-combinator"]
    mock.raise("on_research_finished", {})
    eq(record(e).storage.r, 1)
end)

test("registration pass is identical on apply and load", function()
    local e = build([[
        local force_name = game and game.forces.player.name   -- nil while registering
        if force_name then
            script.on_event(defines.events.on_player_respawned, function() end)
        end
        script.on_event(defines.events.on_player_died, function() storage.died = true end)
        if not entity then return end
        out("signal-A", 1)
    ]], {run_on_timer = false})
    eq(mock.handlers[E.on_player_respawned], nil, "game is nil during registration")
    assert(mock.handlers[E.on_player_died], "registered before the entity guard")
    local before = mock.registrations()
    mock.reload()
    api = mock.interfaces["lua-combinator"]
    eq(mock.registrations(), before)
    eq(mock.outputs_of(e)["virtual/signal-A"], 1, "real run still sees entity")
end)

test("removing a combinator unregisters its events", function()
    local id = E.on_player_crafted_item
    local e = build([[ script.on_event(defines.events.on_player_crafted_item, function() end) ]])
    assert(mock.handlers[id], "registered")
    e.valid = false
    mock.raise("on_player_mined_entity", {entity = setmetatable({valid = true}, {__index = e})})
    eq(storage.combinators[e.unit_number], nil, "record removed")
    eq(mock.handlers[id], nil, "unregistered")
end)

test("blueprint tags restore code; paste copies config", function()
    local src = build([[ out("signal-A", 3) ]], {interval = 33})
    local tagged = {}
    local stack = {valid = true, valid_for_read = true, is_blueprint = true,
                   set_blueprint_entity_tag = function(i, k, v) tagged[i] = {[k] = v} end}
    game.players[1] = {index = 1, valid = true, name = "tester", print = function() end}
    mock.raise("on_player_setup_blueprint", {player_index = 1, stack = stack,
        mapping = {valid = true, get = function() return {[1] = src} end}})
    assert(tagged[1], "tag written")
    local dst = mock.make_combinator()
    mock.raise("on_robot_built_entity", {entity = dst, tags = tagged[1]})
    eq(record(dst).interval, 33)
    eq(mock.outputs_of(dst)["virtual/signal-A"], nil, "not run until its tick")
    mock.tick(33)
    eq(mock.outputs_of(dst)["virtual/signal-A"], 3)

    local other = build()
    mock.raise("on_entity_settings_pasted", {source = src, destination = other})
    eq(record(other).code, record(src).code)
    eq(mock.outputs_of(other)["virtual/signal-A"], 3)
end)

test("wireless channels and shared memory", function()
    local tx = build()
    tx.inputs.red = {mock.sig("iron-plate", 11)}
    api.set_code(tx.unit_number, [[ transmit("ch", {["iron-plate"] = get_signal("iron-plate")}); shared.x = 5 ]])
    local tx2 = build([[ transmit("ch", {["iron-plate"] = 4, ["signal-A"] = 1}) ]])
    local rx = build([[ set_outputs(receive("ch")); out("signal-X", shared.x) ]])
    local o = mock.outputs_of(rx)
    eq(o["item/iron-plate"], 15)
    eq(o["virtual/signal-A"], 1)
    eq(o["virtual/signal-X"], 5)
    tx2.valid = false
    mock.raise("on_entity_died", {entity = setmetatable({valid = true}, {__index = tx2})})
    api.run(rx.unit_number)
    eq(mock.outputs_of(rx)["item/iron-plate"], 11, "dead transmitter removed")
end)

test("state helpers", function()
    local e = build([[
        local v = get_signal("signal-V")
        if rising_edge("v", v > 0) then storage.edges = (storage.edges or 0) + 1 end
        storage.h = hysteresis("h", v, 2, 8)
        storage.avg = average("a", v, 2)
        storage.ev = every(10)
        storage.d = delay("d", v > 0, 3)
    ]], {interval = 1})
    e.inputs.red = {mock.sig("signal-V", 9, "virtual")}
    mock.tick(5)
    e.inputs.red = {}
    mock.tick(1)
    e.inputs.red = {mock.sig("signal-V", 5, "virtual")}
    mock.tick(1)
    local s = record(e).storage
    eq(s.edges, 2, "edges")
    eq(s.h, false, "hysteresis: off at <= low, stays off between thresholds")
    eq(s.avg, 2.5, "average of 0 and 5")
    eq(s.d, false, "delay not yet elapsed")
end)

test("output disabled clears the entity but remembers the buffer", function()
    local e = build([[ out("signal-A", 1) ]])
    api.set_code(e.unit_number, record(e).code, {output_enabled = false})
    eq(e.store.parameters, nil)
    api.set_code(e.unit_number, record(e).code, {output_enabled = true})
    eq(mock.outputs_of(e)["virtual/signal-A"], 1)
end)

test("error marker and chat notification", function()
    local e = build("error('boom')")
    assert(record(e).error_marker and record(e).error_marker.valid, "marker drawn")
    assert(mock.chat[#mock.chat]:find("boom"), "chat")
    local marker = record(e).error_marker
    api.set_code(e.unit_number, "out('signal-A', 1)")
    eq(marker.valid, false, "marker removed")
end)

test("every built-in example compiles and runs without errors", function()
    local examples = require("examples.index")
    assert(#examples >= 40, "expected at least 40 examples, got " .. #examples)
    for _, ex in ipairs(examples) do
        assert(ex.title and ex.description and ex.code, ex.id .. " incomplete")
        local e = build()
        e.inputs.red = {mock.sig("iron-plate", 120), mock.sig("signal-T", 450, "virtual"),
                        mock.sig("water", 9000, "fluid"), mock.sig("signal-A", 30, "virtual")}
        e.inputs.green = {mock.sig("signal-I", 1, "virtual"), mock.sig("signal-N", 12345, "virtual")}
        local err = api.load_example(e.unit_number, ex.id)
        if err then error(ex.id .. ": " .. err) end
        mock.tick(130)
        mock.raise("on_console_chat", {message = "!lights on"})
        mock.raise("on_research_finished", {research = {name = "automation", force = mock.force}})
        mock.raise("on_entity_died", {entity = {valid = true, name = "stone-wall", force = mock.force,
                                                surface = mock.surface, position = {x = 1, y = 1}}})
        mock.raise("on_rocket_launched", {})
        mock.raise("on_player_joined_game", {player_index = 1})
        local r = record(e)
        if r.last_error then error(ex.id .. ": " .. r.last_error) end
        assert(r.stats.runs > 0 or r.stats.events > 0, ex.id .. " never ran")
        api.set_code(e.unit_number, "")   -- unregister its handlers again
    end
end)

test("remote interface", function()
    local e = build()
    local list = api.list()
    assert(#list > 0)
    eq(api.set_code(e.unit_number, "error('x')"):find("x") ~= nil, true)
    eq(api.get_config(e.unit_number).code, "error('x')")
    assert(#api.examples() >= 40)
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
