return {
    title       = "Rocket launch counter",
    description = "Counts rocket launches with on_rocket_launched and pulses signal-L on every launch.",
    interval    = 60,
    timer       = false,
    code = [==[
-- Rocket launch counter (event-driven) ---------------------------------------------
script.on_event(defines.events.on_rocket_launched, function(e)
    storage.launches = (storage.launches or 0) + 1
    set_output("virtual", "signal-R", storage.launches)
    print("Rocket #" .. storage.launches .. " launched!")
end)

-- Every 10 s mirror the force-wide total too (on_nth_tick also works with Timer off).
script.on_nth_tick(600, function()
    set_output("virtual", "signal-T", entity.force.rockets_launched)
end)
]==],
}
