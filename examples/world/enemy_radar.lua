return {
    title       = "Enemy radar",
    description = "Counts enemy units, spawners and worms near the combinator and raises an alert.",
    interval    = 120,
    code = [==[
-- Enemy radar -----------------------------------------------------------------
local RADIUS = 64
if not entity then return end

local surface, pos = entity.surface, entity.position
local function count(types)
    return surface.count_entities_filtered{
        position = pos, radius = RADIUS, force = "enemy", type = types,
    }
end

local units    = count({"unit"})
local spawners = count({"unit-spawner"})
local worms    = count({"turret"})

set_output("virtual", "signal-U", units)
set_output("virtual", "signal-S", spawners)
set_output("virtual", "signal-W", worms)

local danger = units + spawners + worms > 0
set_output("virtual", "signal-red", danger and 1 or 0)
if danger then
    alert(string.format("Enemies nearby: %d units, %d nests, %d worms", units, spawners, worms),
          "signal-red")
end
]==],
}
