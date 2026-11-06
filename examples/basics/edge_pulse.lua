return {
    title       = "Edge detector",
    description = "Turns a level into one-shot pulses and counts how often an input switched on.",
    interval    = 1,
    code = [==[
-- Edge detector ------------------------------------------------------------
-- rising_edge(key, condition) is true for exactly one execution when the
-- condition goes from false to true.  The key names the state slot, so you
-- can track as many conditions as you like.
local active = get_signal("signal-A") > 0

if rising_edge("A", active) then
    storage.presses = (storage.presses or 0) + 1
    set_output("virtual", "signal-P", 1)    -- one-execution pulse
end

if falling_edge("A", active) then
    set_output("virtual", "signal-F", 1)    -- pulse when it switches off
end

set_output("virtual", "signal-C", storage.presses or 0)
]==],
}
