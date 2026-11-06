return {
    title       = "Rocket silo monitor",
    description = "Finds every rocket silo wired to the red input and reports how many are ready.",
    interval    = 60,
    code = [==[
-- Rocket silo monitor ---------------------------------------------------------
-- Wire any number of rocket silos to the red input.
--   signal-G = 1  every silo has a rocket ready
--   signal-Y = 1  at least one silo is still building
--   signal-R = n  silos with a rocket ready
--   signal-T = n  silos found on the network
if not entity then return end

local net = get_network("red")
if not net then return end

local total, ready = 0, 0
local silos = entity.surface.find_entities_filtered{type = "rocket-silo", force = entity.force}
for _, silo in ipairs(silos) do
    local silo_net = silo.get_circuit_network(defines.wire_connector_id.circuit_red)
    if silo_net and silo_net.network_id == net.network_id then
        total = total + 1
        if silo.rocket_silo_status == defines.rocket_silo_status.rocket_ready then
            ready = ready + 1
        end
    end
end

set_output("virtual", "signal-G", (total > 0 and ready == total) and 1 or 0)
set_output("virtual", "signal-Y", ready < total and 1 or 0)
set_output("virtual", "signal-R", ready)
set_output("virtual", "signal-T", total)

if rising_edge("all-ready", total > 0 and ready == total) then
    print("All " .. total .. " rocket silos are ready for launch.")
end
]==],
}
