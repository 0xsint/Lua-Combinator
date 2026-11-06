return {
    title       = "Wireless receiver",
    description = "Outputs everything transmitted on a named channel.",
    interval    = 30,
    code = [==[
-- Wireless receiver --------------------------------------------------------------------
local CHANNEL = "outpost-1"

set_outputs(receive(CHANNEL))
]==],
}
