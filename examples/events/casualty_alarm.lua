return {
    title       = "Casualty alarm",
    description = "Listens to on_entity_died and raises an alarm when your buildings are destroyed nearby.",
    interval    = 60,
    timer       = true,
    code = [==[
-- Casualty alarm ---------------------------------------------------------------------
-- Event handler: count losses near this combinator.
-- Timer (every 60 ticks): decay the alarm after a quiet minute.
local RADIUS = 100

script.on_event(defines.events.on_entity_died, function(e)
    local victim = e.entity
    if not (entity and victim and victim.valid) then return end
    if victim.force ~= entity.force or victim.surface ~= entity.surface then return end
    local dx, dy = victim.position.x - entity.position.x, victim.position.y - entity.position.y
    if dx * dx + dy * dy > RADIUS * RADIUS then return end

    storage.losses = (storage.losses or 0) + 1
    storage.last_loss = game.tick
    alert(rich_text("entity", victim.name, nil) .. " destroyed!", "signal-red")
end)

-- Top-level code is the timer part.
local recent = storage.last_loss and (tick - storage.last_loss) < 3600
set_output("virtual", "signal-red", recent and 1 or 0)
set_output("virtual", "signal-D", storage.losses or 0)
]==],
}
