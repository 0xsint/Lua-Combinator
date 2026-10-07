-- ============================================================
-- Rocket Ready Monitor + Payload Loader
-- ============================================================
-- WIRING:
--   Rocket silo(s)                 → INPUT  wire (red, top)
--   Requester chest + lamps/       → OUTPUT wire (bottom)
--     speakers
--
-- When ALL wired silos have a rocket ready the script:
--   • turns on lamps and speakers on the output wire
--   • sets the requester chest to fetch PAYLOAD_COUNT of
--     PAYLOAD_ITEM so an inserter can load the rocket
--
-- When the rocket launches (parts reset) the chest request is
-- cleared so items stop arriving until the next rocket is ready.
--
--   signal-G  = 1  all silos ready
--   signal-Y  = 1  at least one silo still building
--   signal-R  = N  silos with a completed rocket
--   signal-T  = N  total silos wired to input
--
-- Recommended interval: 60 ticks
-- ============================================================

if not entity then return end

-- ── Configuration ─────────────────────────────────────────────
local PAYLOAD_ITEM   = "big-mining-drill"  -- item name to request
local PAYLOAD_COUNT  = 20                  -- how many to request
local PAYLOAD_SLOT   = 1                   -- chest slot to use

-- ── Scan input (red) network for rocket silos ─────────────────
local in_net = get_network("red")

local silos_total    = 0
local silos_ready    = 0
local silos_building = 0
local all_ready      = false

if in_net then
    local all_silos = entity.surface.find_entities_filtered{
        name  = "rocket-silo",
        force = entity.force,
    }
    for _, silo in ipairs(all_silos) do
        if not silo.valid then goto next_silo end
        if silo.rocket_parts == nil then goto next_silo end

        -- Check if this silo is on our input network.
        -- Silos are non-combinator entities so they use circuit_red/circuit_green.
        local connected = false
        for _, cid in ipairs({
            defines.wire_connector_id.circuit_red,
            defines.wire_connector_id.circuit_green,
        }) do
            local silo_net = silo.get_circuit_network(cid)
            if silo_net and silo_net.network_id == in_net.network_id then
                connected = true
                break
            end
        end
        if not connected then goto next_silo end

        silos_total = silos_total + 1
        if silo.rocket_silo_status == defines.rocket_silo_status.rocket_ready then
            silos_ready = silos_ready + 1
        else
            silos_building = silos_building + 1
        end

        ::next_silo::
    end

    all_ready = silos_total > 0 and silos_ready == silos_total
end

-- ── Derive status ─────────────────────────────────────────────
local any_ready = silos_ready > 0
local building  = silos_building > 0 or (any_ready and not all_ready)

-- ── Emit circuit signals ──────────────────────────────────────
set_output("virtual", "signal-green",  all_ready and 1 or 0)
set_output("virtual", "signal-yellow", building  and 1 or 0)
set_output("virtual", "signal-R",      silos_ready)
set_output("virtual", "signal-T",      silos_total)

-- ── Control entities on the output network ────────────────────
local out_net = get_network("red", "output")
if not out_net then return end

local out_id = out_net.network_id
local area   = {
    { entity.position.x - 64, entity.position.y - 64 },
    { entity.position.x + 64, entity.position.y + 64 },
}

for _, ent in pairs(entity.surface.find_entities_filtered{ area = area }) do
    if not ent.valid then goto next_ent end

    -- Confirm entity is on our output network
    local on_out = false
    for _, cid in ipairs({
        defines.wire_connector_id.combinator_output_red,
        defines.wire_connector_id.combinator_output_green,
        defines.wire_connector_id.circuit_red,
        defines.wire_connector_id.circuit_green,
    }) do
        local ent_net = ent.get_circuit_network(cid)
        if ent_net and ent_net.network_id == out_id then
            on_out = true
            break
        end
    end
    if not on_out then goto next_ent end

    if ent.type == "lamp" then
        local ok, cb = pcall(function() return ent.get_or_create_control_behavior() end)
        if ok and cb then
            pcall(function() cb.enabled = any_ready end)
        end

    elseif ent.type == "programmable-speaker" then
        local ok, cb = pcall(function() return ent.get_or_create_control_behavior() end)
        if ok and cb then
            pcall(function()
                cb.circuit_enable_disable = true
                cb.enabled = all_ready
            end)
        end

    elseif ent.name == "requester-chest" then
        local ls = ent.get_logistic_sections()
        if ls then
            local section = ls.get_section(1)
            if not section then section = ls.add_section() end
            if section and section.valid and section.is_manual then
                if all_ready then
                    pcall(function()
                        section.set_slot(PAYLOAD_SLOT,
                            { value = { type = "item", name = PAYLOAD_ITEM , quality = "normal"}, min = PAYLOAD_COUNT })
                    end)
                else
                    pcall(function()
                        section.clear_slot(PAYLOAD_SLOT)
                    end)
                end
            end
        end
    end

    ::next_ent::
end
