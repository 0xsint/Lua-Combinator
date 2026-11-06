return {
    title       = "Research announcer",
    description = "Announces finished research in chat and counts technologies researched.",
    interval    = 60,
    timer       = false,
    code = [==[
-- Research announcer (event-driven) -------------------------------------------------
script.on_event(defines.events.on_research_finished, function(e)
    local tech = e.research
    if not entity or tech.force ~= entity.force then return end
    storage.done = (storage.done or 0) + 1
    print("Research complete: [technology=" .. tech.name .. "]")
    set_output("virtual", "signal-R", storage.done)
end)
]==],
}
