return {
    title       = "Round-robin sequencer",
    description = "Steps through a list of signals, emitting one per execution – drive a filter inserter or a train schedule.",
    interval    = 120,
    code = [==[
-- Round-robin sequencer -------------------------------------------------------------
-- Each execution outputs the next entry; signal-H (green) holds the sequence.
local SEQUENCE = {
    {"iron-plate", 50},
    {"copper-plate", 50},
    {"steel-plate", 20},
    {"plastic-bar", 20},
}

if get_signal("signal-H", "green") == 0 then
    storage.step = (storage.step or 0) % #SEQUENCE + 1
end
local entry = SEQUENCE[storage.step or 1]

out(entry[1], entry[2])
set_output("virtual", "signal-S", storage.step or 1)
]==],
}
