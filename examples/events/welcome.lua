return {
    title       = "Welcome message",
    description = "Event-driven: greets players as they join and counts online players. Timer off.",
    interval    = 60,
    timer       = false,
    code = [==[
-- Welcome message (event-driven) --------------------------------------------------
-- With Timer unchecked this code only runs when an event fires.  Handlers
-- are registered when you press Apply and again automatically on load.
local function update()
    set_output("virtual", "signal-P", #game.connected_players)
end

script.on_event(defines.events.on_player_joined_game, function(e)
    local player = game.get_player(e.player_index)
    print("Welcome, " .. player.name .. "!  (" .. #game.connected_players .. " online)")
    update()
end)

script.on_event(defines.events.on_player_left_game, update)

-- on_init runs once, with live data, when the code is applied.
script.on_init(update)
]==],
}
