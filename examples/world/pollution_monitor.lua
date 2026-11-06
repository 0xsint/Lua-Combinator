return {
    title       = "Pollution monitor",
    description = "Measures pollution at the combinator's chunk and tracks its trend.",
    interval    = 300,
    code = [==[
-- Pollution monitor -----------------------------------------------------------
if not entity then return end

local pollution = entity.surface.get_pollution(entity.position)
local trend     = rate("pollution", pollution) * 60     -- per minute

set_output("virtual", "signal-P", round(pollution))
set_output("virtual", "signal-T", round(trend))

label(string.format("☁ %s  (%+.1f/min)", format_number(pollution, 1), trend))
]==],
}
