return {
    title       = "Player proximity",
    description = "Detects players within a radius – open gates, switch on lights, greet visitors.",
    interval    = 15,
    code = [==[
-- Player proximity ------------------------------------------------------------
-- signal-P = number of player characters within RADIUS tiles.
local RADIUS = 12
if not entity then return end

local characters = entity.surface.find_entities_filtered{
    type = "character", position = entity.position, radius = RADIUS,
}
set_output("virtual", "signal-P", #characters)

-- Greet each player once per visit.
storage.inside = storage.inside or {}
local now = {}
for _, c in ipairs(characters) do
    local player = c.player
    if player then
        now[player.index] = true
        if not storage.inside[player.index] then
            player.print("Welcome to the base, " .. player.name .. "!")
        end
    end
end
storage.inside = now
]==],
}
