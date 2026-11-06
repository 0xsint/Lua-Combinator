-- ===========================================================================
-- scripts/util.lua  –  Small, dependency-free helpers shared by every module
-- ===========================================================================

local util = {}

util.ENTITY_NAME = "lua-combinator"
util.INT32_MIN   = -2147483648
util.INT32_MAX   =  2147483647

--- Convert any error value into a deterministic string.
--- tostring() on tables/functions yields a memory address that differs
--- between peers; anything stored in `storage` must be identical everywhere
--- or the game desyncs, so non-scalar values go through serpent instead.
function util.error_string(err)
    local t = type(err)
    if t == "string" or t == "number" or t == "boolean" or t == "nil" then
        return tostring(err)
    end
    local ok, s = pcall(serpent.line, err, {sortkeys = true, comment = false})
    return ok and s or ("<" .. t .. " error value>")
end

--- Deterministic, human-readable representation of any value.
function util.inspect(value)
    if type(value) == "table" then
        local ok, s = pcall(serpent.block, value, {sortkeys = true, comment = false, nocode = true})
        return ok and s or "<unserializable table>"
    end
    return tostring(value)
end

--- Join varargs with two spaces, using `fmt` to stringify each argument.
function util.join(fmt, ...)
    local args = table.pack(...)
    local parts = {}
    for i = 1, args.n do parts[i] = fmt(args[i]) end
    return table.concat(parts, "  ")
end

function util.clamp(value, min, max)
    value = tonumber(value) or 0
    if min and value < min then return min end
    if max and value > max then return max end
    return value
end

function util.round(value, decimals)
    value = tonumber(value) or 0
    local mult = 10 ^ (decimals or 0)
    return math.floor(value * mult + 0.5) / mult
end

--- Floor to an integer that fits a circuit-network signal (int32).
function util.to_signal_count(n)
    n = math.floor(tonumber(n) or 0)
    if n < util.INT32_MIN then return util.INT32_MIN end
    if n > util.INT32_MAX then return util.INT32_MAX end
    return n
end

--- 1234567 -> "1.23M"
function util.format_number(n, decimals)
    n = tonumber(n) or 0
    decimals = decimals or 2
    local abs = math.abs(n)
    local suffixes = {{1e12, "T"}, {1e9, "G"}, {1e6, "M"}, {1e3, "k"}}
    for _, s in ipairs(suffixes) do
        if abs >= s[1] then
            return util.round(n / s[1], decimals) .. s[2]
        end
    end
    return tostring(util.round(n, decimals))
end

--- Insert `value` into a sorted array of numbers if it is not there yet.
function util.sorted_insert(array, value)
    local lo, hi = 1, #array
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local v = array[mid]
        if v == value then return false end
        if v < value then lo = mid + 1 else hi = mid - 1 end
    end
    table.insert(array, lo, value)
    return true
end

--- Remove `value` from a sorted array of numbers.
function util.sorted_remove(array, value)
    for i = 1, #array do
        if array[i] == value then
            table.remove(array, i)
            return true
        end
        if array[i] > value then return false end
    end
    return false
end

--- Recursively find a named child inside a GUI element tree.
function util.find_child(element, name)
    if not (element and element.valid) then return nil end
    for _, child in pairs(element.children) do
        if child.name == name then return child end
        local found = util.find_child(child, name)
        if found then return found end
    end
    return nil
end

--- Shallow copy.
function util.copy(t)
    local r = {}
    for k, v in pairs(t) do r[k] = v end
    return r
end

return util
