return {
    title       = "Train stop limit",
    description = "Sets a train stop's limit (signal-L) from how many full train loads fit in the buffer chests.",
    interval    = 60,
    code = [==[
-- Train stop limit ----------------------------------------------------------
-- Red wire: all buffer chests at an unloading station.
-- Output:   signal-L -> train stop with "Set trains limit" enabled.
local ITEM          = "iron-ore"
local CHEST_CAPACITY = 6 * 48 * 50       -- 6 steel chests x 48 slots x 50/stack
local WAGONS        = 4
local WAGON_CAPACITY = 40 * 50           -- 40 slots x 50/stack
local MAX_TRAINS    = 2

local free = CHEST_CAPACITY - get_signal(ITEM, "red")
local train_load = WAGONS * WAGON_CAPACITY
local limit = clamp(math.floor(free / train_load), 0, MAX_TRAINS)

set_output("virtual", "signal-L", limit)
-- A limit of 0 means the signal is absent, which the stop also reads as 0:
-- no trains are sent until there is room for a full load.
]==],
}
