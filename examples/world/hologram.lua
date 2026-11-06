return {
    title       = "Hologram display",
    description = "Draws the five biggest inputs as floating rich text above the combinator.",
    interval    = 30,
    code = [==[
-- Hologram display ------------------------------------------------------------
local LINES = 5

local list = signals()
table.sort(list, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
end)

local rows = {}
for i = 1, math.min(LINES, #list) do
    local s = list[i]
    rows[#rows + 1] = rich_text(s.type, s.name, s.quality) .. " " .. format_number(s.count, 1)
end

label(#rows > 0 and table.concat(rows, "   ") or "[color=gray]no signal[/color]",
      {scale = 1.2})
]==],
}
