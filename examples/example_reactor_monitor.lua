-- ============================================================
-- Reactor / Heat-Exchanger Temperature Monitor
-- Paste this into the Lua Combinator code editor.
-- ============================================================
--
-- WIRING (circuit-network approach):
--   Nuclear reactor or heat exchanger
--       └─ red wire ──► Lua Combinator  (input side, top)
--   Lua Combinator  (output side, bottom)
--       ├─ green wire ──► Lamp           (enable on signal-green = 1)
--       └─ green wire ──► Power switch   (enable on signal-green = 1)
--
-- On the reactor/heat-exchanger, open its GUI and enable
-- "Output signals" → "Read temperature" so it puts its
-- temperature onto the wire.  The signal will appear in the
-- combinator's red-wire signal monitor.  Adjust TEMP_SIGNAL
-- below to match whichever signal name shows up there.
--
-- Alternatively, see the DIRECT API section at the bottom
-- to read temperature without any wiring.
--
-- Recommended interval: 20 ticks (≈3× per second)
-- ============================================================

-- ── Configuration ─────────────────────────────────────────────
-- Name of the signal your reactor/exchanger puts on the wire.
-- Common values: "temperature", "T", or the fluid name e.g. "steam"
local TEMP_SIGNAL = "temperature"

-- Temperature thresholds (°C)
local TEMP_ON  = 500   -- turn the lamp / switch ON  above this value
local TEMP_OFF = 400   -- turn it back OFF below this value (hysteresis gap)

-- Output signal sent to the lamp or power switch.
-- Wire the output side to a lamp and set "Enable when: signal-green = 1",
-- or to a power switch and set "Enable when: signal-green = 1".
local OUT_SIGNAL = "signal-green"

-- ── Read temperature from red wire ───────────────────────────
-- Try both common signal names; check your signal monitor to see
-- which one the reactor is actually putting on the wire.
local temp = red[TEMP_SIGNAL] or red["T"] or red["temperature"] or 0

-- ── Hysteresis state machine ──────────────────────────────────
-- 'storage.enabled' persists across ticks so we have clean
-- on/off switching without rapid toggling near the threshold.
if storage.enabled == nil then storage.enabled = false end

if temp >= TEMP_ON then
    storage.enabled = true
elseif temp <= TEMP_OFF and temp > 0 then
    -- only turn off when we actually have a reading (> 0 avoids
    -- switching off just because the wire is disconnected)
    storage.enabled = false
end

-- ── Write output ──────────────────────────────────────────────
-- Always output signal-T so the output wire is never empty.
-- A value of -1 means "no temperature reading on the wire".
-- This makes it easy to confirm the combinator is running.
set_output("virtual", "signal-T", temp > 0 and math.floor(temp) or -1)

-- Control signal for the lamp / power switch (1 = on, absent = off)
if storage.enabled then
    set_output("virtual", OUT_SIGNAL, 1)
end

-- ── Optional status print ─────────────────────────────────────
-- Uncomment to log temperature changes to chat.
-- storage.last_state = storage.last_state
-- if storage.last_state ~= storage.enabled then
--     storage.last_state = storage.enabled
--     print("Reactor output: " .. (storage.enabled and "ON" or "OFF")
--           .. "  temp=" .. temp .. "°C")
-- end

-- ============================================================
-- DIRECT API APPROACH (no wiring needed for temperature read)
-- ============================================================
-- If you prefer to query the reactor directly through the game
-- API, comment out everything above and use this block instead.
-- Set the surface name and entity position to match your reactor.
--
-- local surface  = game.surfaces["nauvis"]
-- local reactor  = surface.find_entities_filtered{
--     name     = "nuclear-reactor",
--     position = {x = 0, y = 0},   -- ← change to your reactor's position
--     radius   = 5,
-- }[1]
--
-- local temp = reactor and reactor.temperature or 0
--
-- storage.enabled = storage.enabled or false
-- if temp >= TEMP_ON  then storage.enabled = true  end
-- if temp <= TEMP_OFF and temp > 0 then storage.enabled = false end
--
-- if storage.enabled then
--     set_output("virtual", OUT_SIGNAL, 1)
--     set_output("virtual", "signal-T", math.floor(temp))
-- end
