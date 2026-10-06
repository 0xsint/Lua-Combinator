-- ============================================================
-- Iron Plate Monitor  –  paste this into the Lua Combinator
-- ============================================================
-- Wiring: iron chest ──red wire──► Lua Combinator
--         Lua Combinator ──green wire──► Programmable Speaker
--                                        (trigger on signal-red > 0)
-- Set the combinator interval to 60 (checks once per second).
-- ============================================================

local ITEM       = "iron-plate"   -- item to watch
local WARN_LOW   = 200            -- warn level  (orange)
local CRIT_LOW   = 50             -- critical level (red, triggers speaker)
local ALERT_GAP  = 300            -- ticks between repeated alerts (5 s)

-- ---- Read chest ----
local count = red[ITEM] or 0

-- ---- Always output the live count as a virtual signal ----
-- (pipe to a display combinator or lamp on the green wire)
set_output("virtual", "signal-info", count)

-- ---- Status logic ----
storage.last_alert = storage.last_alert or 0

if count <= 0 then
    -- Chest is completely empty
    if tick - storage.last_alert >= ALERT_GAP then
        storage.last_alert = tick
        print("[color=red]⛔ EMPTY: " .. ITEM .. " chest is empty![/color]")
    end
    set_output("virtual", "signal-red",   1)   -- critical flag → speaker
    set_output("virtual", "signal-yellow", 0)

elseif count < CRIT_LOW then
    -- Critically low
    if tick - storage.last_alert >= ALERT_GAP then
        storage.last_alert = tick
        print("[color=red]⚠ CRITICAL: " .. ITEM .. " = " .. count .. " (below " .. CRIT_LOW .. ")[/color]")
    end
    set_output("virtual", "signal-red",   1)
    set_output("virtual", "signal-yellow", 0)

elseif count < WARN_LOW then
    -- Low warning (no sound, just a yellow lamp)
    set_output("virtual", "signal-red",   0)
    set_output("virtual", "signal-yellow", 1)

else
    -- Stock is fine
    storage.last_alert = 0          -- reset so alerts resume if it drops again
    set_output("virtual", "signal-red",   0)
    set_output("virtual", "signal-yellow", 0)
end