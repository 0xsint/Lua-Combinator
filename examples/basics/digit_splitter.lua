return {
    title       = "Digit splitter",
    description = "Splits signal-N into decimal digits (signal-0 = ones, signal-1 = tens, …) for lamp displays.",
    interval    = 5,
    code = [==[
-- Digit splitter ----------------------------------------------------------
-- Feed a number on signal-N; get one signal per decimal place.
-- Pair with a 7-segment lamp display that reads signal-0..signal-5.
local n = math.abs(get_signal("signal-N"))
local DIGITS = 6

for place = 0, DIGITS - 1 do
    local digit = math.floor(n / 10 ^ place) % 10
    -- add 1 so a zero digit still produces a signal (0 would be "absent")
    set_output("virtual", "signal-" .. place, digit + 1)
end
set_output("virtual", "signal-M", get_signal("signal-N") < 0 and 1 or 0)   -- minus sign
]==],
}
