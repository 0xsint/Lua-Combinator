return {
    title       = "Persistent counter",
    description = "Counts executions in storage (survives saves) and resets on signal-R.",
    interval    = 60,
    code = [==[
-- Persistent counter ------------------------------------------------------
-- `storage` is this combinator's own table; it survives save/load.
storage.count = (storage.count or 0) + 1

-- Reset with any positive signal-R on either wire.
if get_signal("signal-R") > 0 then
    storage.count = 0
end

set_output("virtual", "signal-C", storage.count)
]==],
}
