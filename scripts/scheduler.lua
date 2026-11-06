-- ===========================================================================
-- scripts/scheduler.lua  –  Tick buckets for timer-driven execution
-- ===========================================================================
--
-- Instead of looping over every combinator on every tick, each combinator
-- is placed in the bucket for the tick it should next run on:
--
--   storage.schedule[tick] = { unit_number, unit_number, ... }
--
-- on_tick only looks at the bucket for the current tick, so cost scales
-- with the number of combinators that are *due*, not the number that exist.
-- A combinator with interval N runs on ticks divisible by N (same timing
-- as earlier versions), so combinators sharing an interval stay in step.
--
-- Rescheduling never searches buckets: the record's `next_run` is the
-- source of truth and stale bucket entries are skipped when popped.
-- ===========================================================================

local scheduler = {}

function scheduler.init()
    storage.schedule = storage.schedule or {}
end

--- First tick strictly after `tick` that is divisible by `interval`.
function scheduler.next_aligned(tick, interval)
    interval = math.max(1, math.floor(interval or 1))
    return tick - (tick % interval) + interval
end

--- Put `record` in the bucket for `at`.
function scheduler.schedule_at(record, at)
    local bucket = storage.schedule[at]
    if not bucket then
        bucket = {}
        storage.schedule[at] = bucket
    end
    bucket[#bucket + 1] = record.unit_number
    record.next_run = at
end

--- (Re)schedule a record according to its interval/timer settings.
function scheduler.reschedule(record, now)
    if record.run_on_timer == false or not record.code or record.code == "" then
        record.next_run = nil
        return
    end
    scheduler.schedule_at(record, scheduler.next_aligned(now, record.interval))
end

--- Pop the bucket for `tick` and call run(record) for each due combinator.
--- run() must not error (callers wrap user code in pcall).
function scheduler.process(tick, records, run)
    local bucket = storage.schedule[tick]
    if not bucket then return end
    storage.schedule[tick] = nil
    for i = 1, #bucket do
        local record = records[bucket[i]]
        if record and record.next_run == tick then
            record.next_run = nil
            run(record)
            -- run() may have removed the record or changed its settings;
            -- only schedule it again if nothing else already did.
            if records[record.unit_number] == record and record.next_run == nil then
                scheduler.reschedule(record, tick)
            end
        end
    end
end

--- Rebuild every bucket from scratch (migrations / repair).
function scheduler.rebuild(records, now)
    storage.schedule = {}
    local units = {}
    for unit in pairs(records) do units[#units + 1] = unit end
    table.sort(units)
    for _, unit in ipairs(units) do
        scheduler.reschedule(records[unit], now)
    end
end

return scheduler
