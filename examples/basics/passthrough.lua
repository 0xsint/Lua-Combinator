return {
    title       = "Pass-through",
    description = "Forward everything on the red wire to the output, plus one hand-picked signal.",
    interval    = 1,
    code = [==[
-- Pass-through ------------------------------------------------------------
-- forward() copies input signals to the output.  forward("red") copies just
-- the red wire; forward() with no color copies red + green summed.
forward("red")

-- You can still set individual signals afterwards.  out() works out the
-- signal type (item / fluid / virtual) from the name for you.
local iron = get_signal("iron-plate", "green")
if iron > 0 then
    out("iron-plate", iron)
end
]==],
}
