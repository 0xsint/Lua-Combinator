return {
    title       = "Multiplexer",
    description = "Outputs only the N-th red-wire signal, where N comes from signal-I on green.",
    interval    = 1,
    code = [==[
-- Multiplexer ---------------------------------------------------------------
-- signals("red") returns a sorted list: {type, name, quality, count}.
local list  = signals("red")
local index = get_signal("signal-I", "green")

local s = list[index]
if s then
    set_output(s.type, s.name, s.count, s.quality)
end
set_output("virtual", "signal-N", #list)   -- how many there are to choose from
]==],
}
