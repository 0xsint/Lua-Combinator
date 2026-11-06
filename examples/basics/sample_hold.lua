return {
    title       = "Memory cell",
    description = "Sample-and-hold: stores all inputs while signal-S > 0, clears on signal-R.",
    interval    = 1,
    code = [==[
-- Memory cell ---------------------------------------------------------------
-- Green wire: control signals (S = store, R = reset)
-- Red wire:   the data to remember
local store = get_signal("signal-S", "green") > 0
local reset = get_signal("signal-R", "green") > 0

if reset then
    storage.memory = {}
elseif store then
    storage.memory = {}
    for _, s in ipairs(signals("red")) do
        local key = s.quality and (s.name .. "@" .. s.quality) or s.name
        storage.memory[key] = s.count
    end
end

-- set_outputs takes { name = count } and works out each type itself.
set_outputs(storage.memory or {})
]==],
}
