return {
    title       = "Research status",
    description = "Outputs current research progress and queue length, with a floating label.",
    interval    = 60,
    code = [==[
-- Research status -------------------------------------------------------------
-- signal-R = progress of current research in %, signal-Q = queue length.
if not entity then return end
local force = entity.force

local research = force.current_research
local progress = research and round(force.research_progress * 100) or 0
local queue    = force.research_queue or {}

set_output("virtual", "signal-R", progress)
set_output("virtual", "signal-Q", #queue)
set_output("virtual", "signal-check", research and 0 or 1)   -- idle labs!

if research then
    label(string.format("[technology=%s] %d%%", research.name, progress))
else
    label("[color=red]No research queued[/color]")
end
]==],
}
