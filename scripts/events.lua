-- ===========================================================================
-- scripts/events.lua  –  One event multiplexer for the mod and every script
-- ===========================================================================
--
-- Factorio allows exactly one handler per event (and per nth-tick value) per
-- mod.  The mod itself needs on_tick, on_built_entity, GUI events, … and
-- every combinator script may want any of those too.  This module owns all
-- registrations:
--
--   events.on(id, fn)                    internal (mod) handler, permanent
--   events.add_user(id, unit, fn)        script handler for one combinator
--   events.add_user_nth(n, unit, fn)
--   events.remove_unit(unit)             drop all handlers of a combinator
--
-- Script handlers are dispatched in ascending unit-number order so every
-- peer runs them in the same order.  When the last handler for an event
-- disappears the Factorio registration is removed again, so the set of
-- registered events is always exactly what on_load will rebuild (otherwise
-- joining a multiplayer game fails with an event-registration mismatch).
-- ===========================================================================

local util = require("scripts.util")

local events = {}

local internal = {}   -- [event_id] = fn
local user     = {}   -- [event_id] = { units = {sorted unit numbers}, fns = {[unit] = fn} }
local user_nth = {}   -- [n]        = { units = {...}, fns = {...} }

--- Called for every user handler: (unit_number, fn, event_data, kind).
--- Installed by the sandbox module (avoids a circular require).
local user_invoker = function() end
function events.set_user_invoker(fn) user_invoker = fn end

local function run_user(bucket, e, kind)
    -- Iterate over a snapshot: handlers may (un)register while running.
    local units = {}
    for i, u in ipairs(bucket.units) do units[i] = u end
    for _, unit in ipairs(units) do
        local fn = bucket.fns[unit]
        if fn then user_invoker(unit, fn, e, kind) end
    end
end

local function dispatcher(id)
    return function(e)
        local own = internal[id]
        if own then own(e) end
        local bucket = user[id]
        if bucket then run_user(bucket, e, "event") end
    end
end

local function sync(id)
    if internal[id] or (user[id] and #user[id].units > 0) then
        script.on_event(id, dispatcher(id))
    else
        script.on_event(id, nil)
    end
end

local function sync_nth(n)
    local bucket = user_nth[n]
    if bucket and #bucket.units > 0 then
        script.on_nth_tick(n, function(e) run_user(bucket, e, "nth_tick") end)
    else
        user_nth[n] = nil
        script.on_nth_tick(n, nil)
    end
end

--- Register a permanent mod-internal handler (call from the main chunk).
function events.on(id, fn)
    if type(id) == "table" then
        for _, i in ipairs(id) do events.on(i, fn) end
        return
    end
    internal[id] = fn
    sync(id)
end

local function add(store, key, unit, fn)
    local bucket = store[key]
    if not bucket then
        bucket = {units = {}, fns = {}}
        store[key] = bucket
    end
    util.sorted_insert(bucket.units, unit)
    bucket.fns[unit] = fn
end

function events.add_user(id, unit, fn)
    local fresh = not (user[id] and #user[id].units > 0)
    add(user, id, unit, fn)
    if fresh then sync(id) end
end

function events.add_user_nth(n, unit, fn)
    local fresh = not user_nth[n]
    add(user_nth, n, unit, fn)
    if fresh then sync_nth(n) end
end

--- Remove every script handler belonging to `unit`.
function events.remove_unit(unit)
    for id, bucket in pairs(user) do
        if bucket.fns[unit] then
            bucket.fns[unit] = nil
            util.sorted_remove(bucket.units, unit)
            if #bucket.units == 0 then
                user[id] = nil
                sync(id)
            end
        end
    end
    for n, bucket in pairs(user_nth) do
        if bucket.fns[unit] then
            bucket.fns[unit] = nil
            util.sorted_remove(bucket.units, unit)
            if #bucket.units == 0 then sync_nth(n) end
        end
    end
end

--- Debug helper: { events = n, nth = n } counts of active script hooks.
function events.stats(unit)
    local ev, nth = 0, 0
    for _, b in pairs(user) do if b.fns[unit] then ev = ev + 1 end end
    for _, b in pairs(user_nth) do if b.fns[unit] then nth = nth + 1 end end
    return ev, nth
end

return events
