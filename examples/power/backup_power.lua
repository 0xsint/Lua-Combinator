return {
    title       = "Backup power switch",
    description = "Turns backup steam power on when accumulators drop below 20 % and off again above 80 %.",
    interval    = 30,
    code = [==[
-- Backup power switch -------------------------------------------------------
-- Wiring: accumulator ("Read charge" -> signal-A) --red--> combinator
--         combinator --green--> power switch / offshore pump (enable when signal-B > 0)
local LOW, HIGH = 20, 80

local charge = get_signal("signal-A", "red")
-- hysteresis() turns ON at >= HIGH and OFF at <= LOW, i.e. "charged".
-- Backup runs whenever the accumulators are not charged.
local backup = not hysteresis("charged", charge, LOW, HIGH)

set_output("virtual", "signal-B", backup and 1 or 0)
set_output("virtual", "signal-A", charge)

if rising_edge("backup", backup) then
    alert("Backup power engaged at " .. charge .. "% charge", "signal-B")
end
]==],
}
