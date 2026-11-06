return {
    title       = "Production statistics",
    description = "Outputs the force's per-minute production and consumption of chosen items, straight from the game's statistics.",
    interval    = 300,
    code = [==[
-- Production statistics -------------------------------------------------------
-- Output: item signal = produced per minute, signal-C = consumed per minute
-- of the first item in WATCH.
local WATCH = {"iron-plate", "copper-plate", "steel-plate", "electronic-circuit"}
if not entity then return end

local stats = entity.force.get_item_production_statistics(entity.surface)
local function per_minute(name, category)
    return stats.get_flow_count{
        name            = name,
        category        = category,          -- "input" = produced, "output" = consumed
        precision_index = defines.flow_precision_index.one_minute,
        count           = false,
    }
end

for _, name in ipairs(WATCH) do
    set_output("item", name, round(per_minute(name, "input")))
end
set_output("virtual", "signal-C", round(per_minute(WATCH[1], "output")))
]==],
}
