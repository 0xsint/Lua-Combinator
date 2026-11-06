return {
    title       = "Chat-controlled switch",
    description = "Type '!lights on' / '!lights off' / '!set N' in chat to drive circuit signals.",
    interval    = 60,
    timer       = false,
    code = [==[
-- Chat-controlled switch (event-driven) --------------------------------------------
-- Event handlers start from the combinator's current outputs, so changing
-- one signal keeps the others.
script.on_event(defines.events.on_console_chat, function(e)
    local msg = e.message or ""
    if msg == "!lights on" then
        set_output("virtual", "signal-L", 1)
    elseif msg == "!lights off" then
        set_output("virtual", "signal-L", 0)
    else
        local n = msg:match("^!set%s+(-?%d+)$")
        if n then set_output("virtual", "signal-N", tonumber(n)) end
    end
end)
]==],
}
