return {
    title       = "Requester chest controller",
    description = "Drives the logistic requests of requester chests on the output network directly from Lua.",
    interval    = 120,
    code = [==[
-- Requester chest controller --------------------------------------------------
-- Wire one or more requester chests to this combinator's red OUTPUT.
-- The script edits their first logistic section directly through the
-- Factorio API: request REQUEST items while signal-E (green input) > 0,
-- clear the request otherwise.
local ITEM   = "iron-plate"
local AMOUNT = 200
local SLOT   = 1
local RADIUS = 32

if not entity then return end
local out_net = get_network("red", "output")
if not out_net then return end

local wanted = get_signal("signal-E", "green") > 0

local chests = entity.surface.find_entities_filtered{
    name = "requester-chest", position = entity.position, radius = RADIUS,
}
local controlled = 0
for _, chest in ipairs(chests) do
    local net = chest.get_circuit_network(defines.wire_connector_id.circuit_red)
    if net and net.network_id == out_net.network_id then
        local sections = chest.get_logistic_sections()
        local section = sections and (sections.get_section(1) or sections.add_section())
        if section and section.is_manual then
            if wanted then
                section.set_slot(SLOT, {
                    value = {type = "item", name = ITEM, quality = "normal"},
                    min   = AMOUNT,
                })
            else
                section.clear_slot(SLOT)
            end
            controlled = controlled + 1
        end
    end
end

set_output("virtual", "signal-C", controlled)
]==],
}
