return {
    title       = "Throughput meter",
    description = "Measures how fast the total item count on the red wire changes (items/minute), smoothed over 10 samples.",
    interval    = 60,
    code = [==[
-- Throughput meter ----------------------------------------------------------
-- Wire a chest (or a belt in "read belt contents / hold" mode) to red.
-- rate(key, value) returns change per second since the previous call.
local total = 0
for _, s in ipairs(signals("red")) do
    if s.type == "item" then total = total + s.count end
end

local per_minute = rate("total", total) * 60
local smoothed   = average("total", per_minute, 10)

set_output("virtual", "signal-T", total)
set_output("virtual", "signal-F", round(smoothed))     -- net flow, items/min

label(string.format("%s items/min", format_number(smoothed, 1)),
      {color = smoothed >= 0 and {r = 0.4, g = 1, b = 0.4} or {r = 1, g = 0.4, b = 0.4}})
]==],
}
