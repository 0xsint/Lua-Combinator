return {
    title       = "Station state machine",
    description = "A loading-station sequencer: IDLE -> LOADING -> DEPARTING, with timeouts, written as a table of states.",
    interval    = 10,
    code = [==[
-- Station state machine --------------------------------------------------------------
-- Red wire inputs:  signal-T = train present (train stop "read stopped train")
--                   cargo item count from the wagons (inserter/wagon read)
-- Outputs:          signal-I = 1 enable inserters while LOADING
--                   signal-D = 1 tell the train to leave (circuit condition)
--                   signal-S = state number (1..3) for lamps / debugging
local CARGO, FULL = "iron-plate", 4 * 40 * 100
local TIMEOUT     = 60 * 60        -- leave after 60 s even if not full

local STATES = {
    IDLE = {
        id = 1,
        step = function()
            if get_signal("signal-T", "red") > 0 then return "LOADING" end
        end,
    },
    LOADING = {
        id = 2,
        outputs = {["signal-I"] = 1},
        step = function(elapsed)
            if get_signal("signal-T", "red") == 0 then return "IDLE" end
            if get_signal(CARGO, "red") >= FULL or elapsed > TIMEOUT then return "DEPARTING" end
        end,
    },
    DEPARTING = {
        id = 3,
        outputs = {["signal-D"] = 1},
        step = function()
            if get_signal("signal-T", "red") == 0 then return "IDLE" end
        end,
    },
}

storage.state = storage.state or "IDLE"
storage.since = storage.since or tick

local nxt = STATES[storage.state].step(tick - storage.since)
if nxt and nxt ~= storage.state then
    log("station:", storage.state, "->", nxt)
    storage.state, storage.since = nxt, tick
end

local st = STATES[storage.state]
set_outputs(st.outputs or {})
set_output("virtual", "signal-S", st.id)
label(storage.state)
]==],
}
