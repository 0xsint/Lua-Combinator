return {
    title       = "Construction logger",
    description = "Combines several events (built / mined / died) into live counters and a running log.",
    interval    = 60,
    timer       = false,
    code = [==[
-- Construction logger (event-driven) --------------------------------------------------
-- One handler can listen to several events at once by passing a list.
local E = defines.events
local KIND = {
    [E.on_built_entity]        = "built",
    [E.on_robot_built_entity]  = "built",
    [E.on_player_mined_entity] = "mined",
    [E.on_robot_mined_entity]  = "mined",
    [E.on_entity_died]         = "died",
}

script.on_event({E.on_built_entity, E.on_robot_built_entity,
                 E.on_player_mined_entity, E.on_robot_mined_entity,
                 E.on_entity_died}, function(e)
    local victim = e.entity
    if not (victim and victim.valid and entity and victim.force == entity.force) then return end
    local kind = KIND[e.name]
    storage[kind] = (storage[kind] or 0) + 1

    set_output("virtual", "signal-B", storage.built or 0)
    set_output("virtual", "signal-M", storage.mined or 0)
    set_output("virtual", "signal-D", storage.died  or 0)
end)
]==],
}
