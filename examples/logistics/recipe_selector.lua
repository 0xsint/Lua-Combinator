return {
    title       = "Mall recipe selector",
    description = "Picks the item furthest below its target and outputs it alone, for an assembler set to 'Set recipe'.",
    interval    = 120,
    code = [==[
-- Mall recipe selector ------------------------------------------------------
-- Red wire:   the mall's output chest.
-- Output:     exactly one item signal -> assembler with "Set recipe".
-- The choice is sticky: once picked, it is kept until that item reaches its
-- target, so the assembler doesn't thrash between recipes.
local TARGETS = {
    ["transport-belt"]   = 200,
    ["inserter"]         = 100,
    ["fast-inserter"]    = 50,
    ["small-electric-pole"] = 100,
    ["pipe"]             = 100,
    ["assembling-machine-1"] = 20,
}

local function fill_ratio(name)
    return get_signal(name, "red") / TARGETS[name]
end

local current = storage.current
if current and (not TARGETS[current] or fill_ratio(current) >= 1) then
    current = nil
end

if not current then
    -- pick the lowest fill ratio; sort names so ties are deterministic
    local names = {}
    for name in pairs(TARGETS) do names[#names + 1] = name end
    table.sort(names)
    local best, best_ratio = nil, 1
    for _, name in ipairs(names) do
        local r = fill_ratio(name)
        if r < best_ratio then best, best_ratio = name, r end
    end
    current = best
end

storage.current = current
if current then
    out(current, 1)
    label(rich_text(current))
else
    label("idle")
end
]==],
}
