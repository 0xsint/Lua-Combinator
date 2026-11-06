return {
    title       = "Clock & waveforms",
    description = "Generates a sawtooth (signal-S), square wave (signal-Q), sine (signal-W) and a 1-tick pulse (signal-P).",
    interval    = 1,
    code = [==[
-- Clock & waveforms --------------------------------------------------------
local PERIOD = 120          -- ticks per cycle (2 s)

local phase = tick % PERIOD

set_output("virtual", "signal-S", phase)                                 -- sawtooth 0..119
set_output("virtual", "signal-Q", phase < PERIOD / 2 and 1 or 0)        -- square wave
set_output("virtual", "signal-W", round(100 * math.sin(2 * math.pi * phase / PERIOD)))
set_output("virtual", "signal-P", phase == 0 and 1 or 0)                -- pulse once per cycle
]==],
}
