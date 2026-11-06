-- ===========================================================================
-- examples/index.lua  –  Catalogue of the built-in example scripts
-- ===========================================================================
-- Every example is a module returning
--   { title = string, description = string, interval = uint,
--     timer = bool (default true), code = string }
-- The GUI's example browser lists them in this order.  To add one, drop a
-- file in the right folder and add its path below.
-- ===========================================================================

local CATALOGUE = {
    {category = "Basics", items = {
        "basics.passthrough",
        "basics.counter",
        "basics.filter_scale",
        "basics.clock",
        "basics.edge_pulse",
        "basics.sample_hold",
        "basics.multiplexer",
        "basics.top_n",
        "basics.digit_splitter",
        "basics.statistics",
    }},
    {category = "Logistics", items = {
        "logistics.stock_monitor",
        "logistics.restock_planner",
        "logistics.recipe_selector",
        "logistics.train_limit",
        "logistics.throughput_meter",
        "logistics.rocket_monitor",
        "logistics.requester_controller",
    }},
    {category = "Power & fluids", items = {
        "power.reactor_monitor",
        "power.backup_power",
        "power.pid_tank",
    }},
    {category = "World & game API", items = {
        "world.day_night",
        "world.pollution_monitor",
        "world.enemy_radar",
        "world.player_proximity",
        "world.research_status",
        "world.production_stats",
        "world.map_tag",
        "world.hologram",
        "world.life_display",
    }},
    {category = "Events", items = {
        "events.welcome",
        "events.rocket_counter",
        "events.casualty_alarm",
        "events.chat_switch",
        "events.research_announcer",
    }},
    {category = "Wireless & shared state", items = {
        "network.wireless_transmitter",
        "network.wireless_receiver",
        "network.shared_memory",
    }},
    {category = "Advanced", items = {
        "advanced.state_machine",
        "advanced.sequencer",
        "advanced.morse",
        "advanced.event_bus",
    }},
}

local list = {}
for _, group in ipairs(CATALOGUE) do
    for _, path in ipairs(group.items) do
        local ex = require("examples." .. path)
        list[#list + 1] = {
            id          = path,
            category    = group.category,
            title       = ex.title,
            description = ex.description,
            interval    = ex.interval or 20,
            timer       = ex.timer ~= false,
            code        = ex.code,
        }
    end
end

return list
