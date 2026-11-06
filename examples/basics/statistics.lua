return {
    title       = "Signal statistics",
    description = "Sum, count, min, max and average of every item on the input wires.",
    interval    = 30,
    code = [==[
-- Signal statistics -------------------------------------------------------
local sum, count = 0, 0
local min, max

for _, s in ipairs(signals()) do
    if s.type == "item" then
        sum   = sum + s.count
        count = count + 1
        min   = math.min(min or s.count, s.count)
        max   = math.max(max or s.count, s.count)
    end
end

set_output("virtual", "signal-S", sum)
set_output("virtual", "signal-C", count)
set_output("virtual", "signal-L", min or 0)
set_output("virtual", "signal-H", max or 0)
set_output("virtual", "signal-A", count > 0 and round(sum / count) or 0)
]==],
}
