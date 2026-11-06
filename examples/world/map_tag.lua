return {
    title       = "Live map tag",
    description = "Keeps a map (chart) tag next to the combinator updated with live numbers from the red wire.",
    interval    = 300,
    code = [==[
-- Live map tag ----------------------------------------------------------------
-- Shows e.g. "Iron 12.3k | Copper 8k" on the map at the combinator.
local SHOW = {"iron-plate", "copper-plate", "steel-plate"}
if not entity then return end

local parts = {}
for _, name in ipairs(SHOW) do
    parts[#parts + 1] = rich_text(name) .. " " .. format_number(get_signal(name, "red"), 1)
end
local text = table.concat(parts, "  ")

local tag = storage.tag
if tag and tag.valid then
    tag.text = text
else
    storage.tag = entity.force.add_chart_tag(entity.surface, {
        position = entity.position,
        text     = text,
        icon     = {type = "virtual", name = "signal-lua-combinator"},
    })
    -- add_chart_tag returns nil when the area isn't charted yet; we'll retry.
end
]==],
}
