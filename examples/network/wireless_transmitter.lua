return {
    title       = "Wireless transmitter",
    description = "Broadcasts every input signal on a named channel – no wires across the map needed.",
    interval    = 30,
    code = [==[
-- Wireless transmitter ---------------------------------------------------------------
-- Pair with "Wireless receiver" using the same CHANNEL, anywhere on any surface.
-- Several transmitters on one channel are summed, just like a circuit network.
local CHANNEL = "outpost-1"

local values = {}
for _, s in ipairs(signals()) do
    local key = s.quality and (s.name .. "@" .. s.quality) or s.name
    values[key] = s.count
end
transmit(CHANNEL, values)

set_output("virtual", "signal-T", 1)   -- "transmitting" indicator
]==],
}
