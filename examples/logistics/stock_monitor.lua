return {
    title       = "Stock monitor",
    description = "Watches one item in a chest: yellow/red status signals, chat warnings and a map alert when it runs low.",
    interval    = 60,
    code = [==[
-- Stock monitor -------------------------------------------------------------
-- Wiring: chest --red--> Lua Combinator --green--> lamps / speaker
local ITEM     = "iron-plate"
local WARN_LOW = 200       -- yellow
local CRIT_LOW = 50        -- red + alert

local count = get_signal(ITEM, "red")
set_output("virtual", "signal-info", count)

local critical = count < CRIT_LOW
local low      = count < WARN_LOW

set_output("virtual", "signal-red",    critical and 1 or 0)
set_output("virtual", "signal-yellow", (low and not critical) and 1 or 0)
set_output("virtual", "signal-green",  (not low) and 1 or 0)

-- Announce once when it becomes critical, not every execution.
if rising_edge("critical", critical) then
    print("[color=red]Low stock:[/color] " .. rich_text(ITEM) .. " only " .. count .. " left")
end
-- Map alert keeps showing while the condition holds.
if critical then
    alert(rich_text(ITEM) .. " is running out (" .. count .. ")", ITEM)
end
]==],
}
