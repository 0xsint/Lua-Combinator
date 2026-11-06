-- ===========================================================================
-- scripts/outputs.lua  –  Output buffers and writing them to the entity
-- ===========================================================================
--
-- A Lua Combinator is a re-skinned decider combinator.  Its outputs are
-- written as constant decider outputs behind an always-true condition.
--
-- Scripts never touch the entity's control behaviour directly; they fill an
-- *output buffer* ({ [key] = {signal = SignalID, count = n} }).  After the
-- script finishes the buffer is compared with what is already on the entity
-- (via a deterministic signature) and only written when it changed, so a
-- combinator that outputs the same thing every tick costs almost nothing.
-- ===========================================================================

local util    = require("scripts.util")
local signals = require("scripts.signals")

local outputs = {}

--- Buffer key: "type/name" or "type/name@quality".
function outputs.key(sig_type, name, quality)
    return sig_type .. "/" .. signals.key(name, quality)
end

--- Sorted array of buffer entries (deterministic order).
function outputs.sorted(buffer)
    local list = {}
    for _, entry in pairs(buffer) do list[#list + 1] = entry end
    table.sort(list, function(a, b)
        return signals.compare(
            {type = a.signal.type, name = a.signal.name, quality = a.signal.quality},
            {type = b.signal.type, name = b.signal.name, quality = b.signal.quality})
    end)
    return list
end

--- Deterministic string describing a buffer, used for change detection.
function outputs.signature(list)
    local parts = {}
    for i, e in ipairs(list) do
        parts[i] = e.signal.type .. "/" .. e.signal.name .. "@" .. (e.signal.quality or "") .. "=" .. e.count
    end
    return table.concat(parts, ";")
end

--- Copy a buffer (entries are copied too, so edits don't alias).
function outputs.copy(buffer)
    local r = {}
    if buffer then
        for k, e in pairs(buffer) do
            r[k] = {signal = {type = e.signal.type, name = e.signal.name, quality = e.signal.quality}, count = e.count}
        end
    end
    return r
end

--- Write `buffer` to the record's entity if it differs from what is there.
--- Returns true on success, or false plus an error message.
function outputs.apply(record, buffer, force)
    local entity = record.entity
    if not (entity and entity.valid) then return true end

    local list = {}
    if record.output_enabled ~= false then list = outputs.sorted(buffer) end
    local sig = outputs.signature(list)
    if not force and record.output_signature == sig then return true end

    local behavior = entity.get_or_create_control_behavior()
    local ok, err = pcall(function()
        if #list == 0 then
            behavior.parameters = nil
            return
        end
        local outs = {}
        for i, e in ipairs(list) do
            outs[i] = {
                signal                = {type = e.signal.type, name = e.signal.name, quality = e.signal.quality},
                copy_count_from_input = false,
                constant              = util.to_signal_count(e.count),
            }
        end
        -- Assign the whole parameter block at once.  An empty condition
        -- (no first signal, constant 0, "=") compares 0 = 0 and is
        -- therefore permanently true.
        behavior.parameters = {
            conditions = {{comparator = "=", constant = 0}},
            outputs    = outs,
        }
    end)
    if not ok then
        record.output_signature = nil
        return false, util.error_string(err)
    end
    record.output_signature = sig
    record.outputs = buffer
    return true
end

--- Remove every output from the entity and forget the buffer.
function outputs.clear(record)
    record.outputs = {}
    return outputs.apply(record, {}, true)
end

return outputs
