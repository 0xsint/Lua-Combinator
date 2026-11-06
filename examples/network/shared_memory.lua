return {
    title       = "Shared memory",
    description = "Uses the `shared` table to keep a factory-wide tally that every Lua Combinator can read and update.",
    interval    = 60,
    code = [==[
-- Shared memory --------------------------------------------------------------------------
-- `storage` is private to this combinator; `shared` is one table shared by
-- every Lua Combinator in the save.  Here each combinator reports how many
-- items it sees, and every one of them can output the factory-wide total.
shared.items = shared.items or {}

local mine = 0
for _, s in ipairs(signals()) do
    if s.type == "item" then mine = mine + s.count end
end
shared.items[unit_number] = mine       -- unit_number identifies this combinator

local total, reporters = 0, 0
for unit, n in pairs(shared.items) do
    -- forget combinators that no longer exist
    if game.get_entity_by_unit_number(unit) then
        total, reporters = total + n, reporters + 1
    else
        shared.items[unit] = nil
    end
end

set_output("virtual", "signal-M", mine)
set_output("virtual", "signal-T", total)
set_output("virtual", "signal-C", reporters)
]==],
}
