return {
    title       = "Reactor temperature",
    description = "Hysteresis on a reactor/heat-exchanger temperature: signal-green switches on above 500 °C and off below 400 °C.",
    interval    = 20,
    code = [==[
-- Reactor temperature -------------------------------------------------------
-- Wiring: reactor (with "Read temperature" enabled) --red--> combinator
--         combinator --green--> lamp / power switch (enable on signal-green = 1)
local TEMP_SIGNAL = "signal-T"   -- the reactor's temperature output signal
local TEMP_ON     = 500
local TEMP_OFF    = 400

-- red[...] is nil when the signal is absent, unlike get_signal() which
-- returns 0.  That lets us tell "no reading" apart from "0 °C".
local temp = red[TEMP_SIGNAL]
if temp == nil then
    set_output("virtual", "signal-T", -1)       -- -1 = no reading
    return
end

local on = hysteresis("reactor", temp, TEMP_OFF, TEMP_ON)
set_output("virtual", "signal-T", temp)
set_output("virtual", "signal-green", on and 1 or 0)

local switched, was = changed("state", on)
if switched and was ~= nil then
    log("reactor output", on and "ON" or "OFF", "at", temp, "C")
end
]==],
}
