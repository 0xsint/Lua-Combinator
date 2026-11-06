return {
    title       = "PID tank level (PWM pump)",
    description = "A PID controller keeps a storage tank at a set level by pulse-width-modulating a pump.",
    interval    = 5,
    code = [==[
-- PID tank level ------------------------------------------------------------
-- Wiring: storage tank --red--> combinator --green--> pump (enable when signal-P > 0)
-- Pumps are on/off, so the PID output (0..1) becomes a duty cycle: the pump
-- is on for that fraction of every PWM_PERIOD ticks.
local FLUID      = "water"
local SETPOINT   = 12500         -- half of a 25k storage tank
local PWM_PERIOD = 60

local level = get_signal(FLUID, "red")

-- pid(key, setpoint, measured, kp, ki, kd, min, max)
-- error is positive when the tank is too LOW, so more duty = more filling.
local duty = pid("tank", SETPOINT, level, 0.0004, 0.00002, 0.0001, 0, 1)

local on = (tick % PWM_PERIOD) < duty * PWM_PERIOD
set_output("virtual", "signal-P", on and 1 or 0)
set_output("virtual", "signal-D", round(duty * 100))   -- duty cycle in %
set_output("virtual", "signal-L", level)
]==],
}
