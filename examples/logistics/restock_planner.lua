return {
    title       = "Restock planner",
    description = "Compares chest contents against a target list and outputs what is missing.",
    interval    = 60,
    code = [==[
-- Restock planner -----------------------------------------------------------
-- Red wire: contents of a storage chest / logistic network.
-- Output:   positive counts of everything below its target.  Feed it to a
--           requester chest set to "Set requests" or to a train schedule.
local TARGETS = {
    ["iron-plate"]        = 400,
    ["copper-plate"]      = 400,
    ["steel-plate"]       = 200,
    ["electronic-circuit"]= 200,
    ["iron-gear-wheel"]   = 100,
}

local missing_total = 0
local missing = {}
for name, target in pairs(TARGETS) do
    local have = get_signal(name, "red")
    if have < target then
        missing[name] = target - have
        missing_total = missing_total + (target - have)
    end
end

set_outputs(missing)
set_output("virtual", "signal-T", missing_total)
]==],
}
