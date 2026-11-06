return {
    title       = "Day / night sensor",
    description = "Reads the surface's darkness and time of day; switches lamps on at dusk.",
    interval    = 60,
    code = [==[
-- Day / night sensor ----------------------------------------------------------
-- Signals:  signal-D = darkness 0..100,  signal-T = time of day 0..999,
--           signal-L = 1 while it is dark enough for lights.
if not entity then return end
local surface = entity.surface

local darkness = round(surface.darkness * 100)
set_output("virtual", "signal-D", darkness)
set_output("virtual", "signal-T", math.floor(surface.daytime * 1000))
set_output("virtual", "signal-L", hysteresis("dark", darkness, 20, 40) and 1 or 0)
]==],
}
