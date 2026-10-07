-- ============================================================
-- Rocket Ready Monitor + Payload Loader
-- ============================================================
-- WIRING:
--   Rocket silo(s)                 → INPUT  wire (red, top)
--   Requester chest + lamps/       → OUTPUT wire (bottom)
--     speakers
--
-- The requester chest on Vulcanus continuously requests PAYLOAD_COUNT
-- of PAYLOAD_ITEM. Lamps and speakers still indicate rocket readiness.
--
-- The request is cleared on other surfaces.
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

if in_net then
    local all_silos = entity.surface.find_entities_filtered{
        name  = "rocket-silo",
        force = entity.force,
    }
    for _, silo in ipairs(all_silos) do
        if not silo.valid then goto next_silo end
        if silo.rocket_parts == nil then goto next_silo end

        -- Rocket silos use circuit_red/circuit_green for their wire connectors.
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
end

-- ── Derive status ─────────────────────────────────────────────
local all_ready = silos_total > 0 and silos_ready == silos_total
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
    if not ent.valid  then goto skip end
    if ent.surface.name == "nauvis" then goto skip end
    if ent == entity  then goto skip end

    -- Confirm entity is on our output network
    local on_out = false
    for _, cid in ipairs({
        defines.wire_connector_id.circuit_red,
    }) do
        local ok, net = pcall(ent.get_circuit_network, cid)
        if ok and net and net.network_id == 947 then
            on_out = true
            break
        end
    end
    if not on_out then goto skip end

    local ok_cb, cb = pcall(function()
        return ent.get_or_create_control_behavior()
    end)
    if not (ok_cb and cb) then goto skip end

    if ent.type == "lamp" then
        -- Light up as soon as any rocket is ready
        pcall(function() cb.enabled = any_ready end)

    elseif ent.type == "programmable-speaker" then
        -- Sound the alert only when every wired silo is ready
        pcall(function()
            cb.circuit_enable_disable = true
            cb.enabled = all_ready
        end)

    elseif ent.name == "requester-chest" then
        -- Factorio 2.0: requests are managed via LuaLogisticSections.
        local ls = ent.get_logistic_sections()
        if not ls then
            goto skip
        end

        local section = ls.get_section(1)
        if not section then
            section = ls.add_section()
        end

        if not (section and section.valid and section.is_manual) then goto skip end
            section.set_slot(PAYLOAD_SLOT, {
                value = { type = "item", name = PAYLOAD_ITEM, quality = "normal"},
                min = PAYLOAD_COUNT, max = PAYLOAD_COUNT
            })
        else
            section.clear_slot(PAYLOAD_SLOT)
        end

    ::skip::
end