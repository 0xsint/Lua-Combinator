return {
    title       = "Top-N selector",
    description = "Finds the N most plentiful items on the input and outputs only those.",
    interval    = 30,
    code = [==[
-- Top-N selector ----------------------------------------------------------
local N = 5

local items = {}
for _, s in ipairs(signals()) do
    if s.type == "item" then items[#items + 1] = s end
end

table.sort(items, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name      -- tie-break keeps the result deterministic
end)

for i = 1, math.min(N, #items) do
    local s = items[i]
    set_output(s.type, s.name, s.count, s.quality)
    -- also emit the rank as signal-1 .. signal-5 style index
    set_output("virtual", "signal-" .. i, s.count)
end
]==],
}
