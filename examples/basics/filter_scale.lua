return {
    title       = "Filter & scale",
    description = "Keep only items above a threshold, multiply them, and drop everything else.",
    interval    = 10,
    code = [==[
-- Filter & scale ----------------------------------------------------------
-- forward() accepts a filter.  Return false to drop a signal, true to keep
-- it unchanged, or a number to replace its value.
local THRESHOLD  = 100
local MULTIPLIER = 2

forward(function(sig)
    if sig.type ~= "item" then return false end          -- items only
    if sig.count < THRESHOLD then return false end       -- ignore small stacks
    return sig.count * MULTIPLIER                         -- scaled value
end)
]==],
}
