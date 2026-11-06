-- ===========================================================================
-- scripts/signals.lua  –  Reading circuit networks and naming signals
-- ===========================================================================
--
-- Conventions used throughout the script API:
--   * A signal's *key* is its name for normal quality ("iron-plate") and
--     "name@quality" otherwise ("iron-plate@rare").  red/green tables and
--     get_signal() use keys.
--   * A signal *record* is { type = ..., name = ..., quality = ..., count = ... }
--     (quality is nil for normal quality).  signals() returns records.
-- ===========================================================================

local signals = {}

--- Wire-connector ids for each (side, color) combination.
signals.WIRES = {
    input  = {
        red   = defines.wire_connector_id.combinator_input_red,
        green = defines.wire_connector_id.combinator_input_green,
    },
    output = {
        red   = defines.wire_connector_id.combinator_output_red,
        green = defines.wire_connector_id.combinator_output_green,
    },
}

--- Signal type -> name of the matching table on the `prototypes` global.
signals.PROTOTYPE_TABLES = {
    ["item"]           = "item",
    ["fluid"]          = "fluid",
    ["virtual"]        = "virtual_signal",
    ["entity"]         = "entity",
    ["recipe"]         = "recipe",
    ["quality"]        = "quality",
    ["space-location"] = "space_location",
    ["asteroid-chunk"] = "asteroid_chunk",
}

--- Signal type -> rich-text tag.
signals.RICH_TEXT_TAGS = {
    ["item"]           = "item",
    ["fluid"]          = "fluid",
    ["virtual"]        = "virtual-signal",
    ["entity"]         = "entity",
    ["recipe"]         = "recipe",
    ["quality"]        = "quality",
    ["space-location"] = "space-location",
    ["asteroid-chunk"] = "asteroid-chunk",
}

--- Virtual signals that cannot be emitted as constant outputs.
signals.WILDCARDS = {
    ["signal-everything"] = true,
    ["signal-anything"]   = true,
    ["signal-each"]       = true,
}

--- Order in which signals() sorts types.
local TYPE_ORDER = {
    ["item"] = 1, ["fluid"] = 2, ["virtual"] = 3, ["entity"] = 4, ["recipe"] = 5,
    ["quality"] = 6, ["space-location"] = 7, ["asteroid-chunk"] = 8,
}

function signals.key(name, quality)
    if quality == nil or quality == "normal" then return name end
    return name .. "@" .. quality
end

--- Split "iron-plate@rare" -> "iron-plate", "rare".
function signals.split_key(key)
    local name, quality = string.match(key, "^(.-)@([^@]+)$")
    if name and name ~= "" then return name, quality end
    return key, nil
end

--- Sort comparator for signal records: by type, name, quality.
function signals.compare(a, b)
    local ta, tb = TYPE_ORDER[a.type] or 99, TYPE_ORDER[b.type] or 99
    if ta ~= tb then return ta < tb end
    if a.name ~= b.name then return a.name < b.name end
    return (a.quality or "") < (b.quality or "")
end

--- Read one circuit network into (map key->count, sorted array of records).
--- Missing networks produce empty results.
function signals.read_network(network)
    local map, list = {}, {}
    if network and network.signals then
        for _, s in pairs(network.signals) do
            local sig = s.signal
            local quality = sig.quality
            if quality == "normal" then quality = nil end
            local rec = {type = sig.type or "item", name = sig.name, quality = quality, count = s.count}
            map[signals.key(rec.name, quality)] = s.count
            list[#list + 1] = rec
        end
        table.sort(list, signals.compare)
    end
    return map, list
end

--- Merge two sorted record lists, summing equal signals.
function signals.merge(a, b)
    local index, out = {}, {}
    local function add(list)
        for _, r in ipairs(list) do
            local k = r.type .. "/" .. signals.key(r.name, r.quality)
            local existing = index[k]
            if existing then
                existing.count = existing.count + r.count
            else
                local copy = {type = r.type, name = r.name, quality = r.quality, count = r.count}
                index[k] = copy
                out[#out + 1] = copy
            end
        end
    end
    add(a); add(b)
    table.sort(out, signals.compare)
    return out
end

-- Prototype lookups are immutable at runtime, so the type of a bare signal
-- name can be resolved once and cached.  The cache is a plain upvalue: it
-- is derived purely from prototypes, so every peer computes the same values.
local type_cache = {}

--- Guess a signal's type from its name: virtual, then item, then fluid,
--- then the less common kinds.  Returns nil if no prototype matches.
function signals.resolve_type(name)
    local cached = type_cache[name]
    if cached ~= nil then return cached or nil end
    local found = false
    for _, t in ipairs{"virtual", "item", "fluid", "entity", "recipe", "quality", "space-location", "asteroid-chunk"} do
        local tbl = prototypes[signals.PROTOTYPE_TABLES[t]]
        if tbl and tbl[name] then found = t break end
    end
    type_cache[name] = found
    return found or nil
end

--- True when (type, name) names an existing prototype.
function signals.exists(sig_type, name)
    local tname = signals.PROTOTYPE_TABLES[sig_type]
    if not tname then return false end
    local tbl = prototypes[tname]
    return tbl ~= nil and tbl[name] ~= nil
end

function signals.quality_exists(quality)
    return quality == nil or (prototypes.quality and prototypes.quality[quality] ~= nil)
end

--- "[item=iron-plate,quality=rare]" style rich text for chat/labels.
function signals.rich_text(sig_type, name, quality)
    if name == nil then
        -- rich_text("iron-plate") form: resolve the type ourselves
        name, quality = signals.split_key(sig_type)
        sig_type = signals.resolve_type(name)
        if not sig_type then return name end
    end
    local tag = signals.RICH_TEXT_TAGS[sig_type] or "item"
    if quality and quality ~= "normal" then
        return "[" .. tag .. "=" .. name .. ",quality=" .. quality .. "]"
    end
    return "[" .. tag .. "=" .. name .. "]"
end

return signals
