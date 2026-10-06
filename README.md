# Lua Combinator — Code Review & Technical README

> A Factorio 2.0 mod that adds a fully programmable combinator to the circuit
> network. Instead of the usual dropdown of arithmetic/decider operations,
> you get a text box: write real Lua, read red/green wire signals, persist
> state across ticks, and emit arbitrary output signals.

This document is an in-depth review of the mod's source, its runtime
architecture, the sandbox API it exposes to user scripts, and — in
particular — a line-by-line walkthrough of the most advanced bundled
example, [`examples/example_rocket_monitor.lua`](/c:/Users/Admin/Desktop/LuaCode/lua-combinator/examples/example_rocket_monitor.lua).

---

## 1. Project layout

| Path | Role |
|---|---|
| [info.json](/c:/Users/Admin/Desktop/LuaCode/lua-combinator/info.json) | Factorio mod manifest (name `lua-combinator`, v1.1.0, requires `base >= 2.0.0`, targets `factorio_version 2.0`). |
| [data.lua](/c:/Users/Admin/Desktop/LuaCode/lua-combinator/data.lua) | Prototype stage: clones the vanilla decider-combinator entity, re-tints it teal/cyan, and registers the item, recipe, and technology. |
| [control.lua](/c:/Users/Admin/Desktop/LuaCode/lua-combinator/control.lua) | Runtime stage (~900 lines): the sandboxed Lua execution engine, event dispatch shim, persistence, and the in-game code-editor GUI. |
| [locale/en/locale.cfg](/c:/Users/Admin/Desktop/LuaCode/lua-combinator/locale/en/locale.cfg) | English localization strings for the entity, item, recipe, technology, and GUI. |
| [examples/](/c:/Users/Admin/Desktop/LuaCode/lua-combinator/examples) | Four ready-to-paste example scripts demonstrating the API (see §4). |
| [screenshot.png](/c:/Users/Admin/Desktop/LuaCode/lua-combinator/screenshot.png) | Promotional/portal screenshot. |

The mod follows the standard two-stage Factorio mod lifecycle: `data.lua`
runs once during the **prototype/data stage** (defines what the entity *is*),
and `control.lua` runs during the **runtime/control stage** (defines what the
entity *does* every tick, in response to events, and in its GUI).

---

## 2. `data.lua` — prototype definition

```lua
local entity = table.deepcopy(data.raw["decider-combinator"]["decider-combinator"])
entity.name           = "lua-combinator"
entity.minable.result = "lua-combinator"
```

Rather than authoring a new entity prototype from scratch (which would
require redefining all of the decider-combinator's connection points, wire
positions, animations, and collision data), the mod **deep-copies the
vanilla `decider-combinator` prototype** and renames it. This is a
pragmatic, low-maintenance technique: it automatically inherits any
balance/visual changes Wube makes to the base combinator in future game
updates.

A small recursive helper then retints every sprite layer:

```lua
local function apply_tint(t, tint)
    if type(t) ~= "table" then return end
    if t.filename then t.tint = tint end
    for i = 1, #t do apply_tint(t[i], tint) end
    for _, key in ipairs{"layers", "hr_version", "north", "south", "east", "west", "sheets"} do
        if t[key] then apply_tint(t[key], tint) end
    end
end
```

This walks arbitrarily nested `SpriteVariations`/`RotatedSprite` structures
(numbered array entries *and* named directional/layer keys) and stamps a
`tint` field onto any table that looks like a sprite definition (i.e. has a
`filename`). It's a generic enough pattern that it would survive future
additions to the decider-combinator's sprite tree without needing edits.

The item, recipe, and technology are then declared conventionally:
- **Item**: `stack_size = 50`, placed in the `circuit-network` subgroup,
  ordered right after the decider combinator (`c[combinators]-d[lua-combinator]`).
- **Recipe**: disabled by default (`enabled = false`), costs 1
  constant-combinator + 3 advanced-circuits + 1 processing-unit — a
  deliberately "mid-to-late game" cost reflecting its power.
- **Technology**: prerequisite `circuit-network`, costs automation +
  logistic + chemical science packs (150 units), unlocks the recipe.

Everything is registered in one call: `data:extend{entity, item, recipe, technology}`.

---

## 3. `control.lua` — the runtime engine

This is the heart of the mod. It is organized into six clearly commented
sections. A high-level tour:

### 3.1 Utilities (Section 1)
- `find_child(element, name)` — recursive GUI-tree search, used by the code
  editor to locate labeled sub-elements (e.g. the signal-monitor text boxes)
  without needing to store direct references everywhere.
- `safe_error_string(err)` — **this is a subtle correctness detail worth
  calling out**: Lua's `tostring()` on a table/function prints a raw memory
  address (`table: 0x0000018f2a3b4580`). Since combinator errors are written
  into `storage` (which is part of Factorio's deterministic, checksummed,
  multiplayer-synced save state), two peers in a multiplayer game could
  format the *same* error differently and **desync** the game. The mod
  guards against this by serializing non-primitive error values with
  `serpent.line` (Factorio's bundled deterministic serializer) instead of
  relying on `tostring`.
- `format_signals(net)` — pretty-prints a `LuaCircuitNetwork`'s current
  signals as `[type] name = count` lines, sorted for determinism, used to
  populate the live signal-monitor panels in the GUI.

### 3.2 Managed script-event dispatch (Section 1b)
Factorio only allows **one** registered handler per event per mod. Since
each Lua Combinator entity can register its own `script.on_event(...)` /
`script.on_nth_tick(...)` calls from inside its sandboxed code, the mod
can't let user code call the real `script.on_event` directly — the last
combinator to register would silently clobber every other combinator's
handler for that event.

Instead it implements its own tiny **pub/sub multiplexer**:

```lua
local event_dispatch    = {}   -- [event_id] = { [unit_number] = fn }
local nth_tick_dispatch = {}   -- [n]        = { [unit_number] = fn }
```

`make_script_wrapper(unit_number)` returns a fake `script` table exposed
inside the sandbox. Its `on_event`/`on_nth_tick` register the combinator's
handler into the dispatch tables above, and lazily register **one real**
`script.on_event`/`script.on_nth_tick` per event id/interval (guarded by
`registered_events` / `registered_nth` so it only happens once ever). The
real handler just calls `dispatch_event`/`dispatch_nth_tick`, which fan out
to every combinator subscribed to that event, each wrapped in its own
`pcall` so one buggy script can't break another combinator's handler (the
error is simply recorded in that combinator's `last_error`).

Because Lua closures (and hence these dispatch tables) are **not
serializable** by Factorio's save system, every handler must be
re-registered from source on every load. That's the job of
`run_setup_pass()`, invoked from `on_init`, `on_configuration_changed`, and
`on_load` — it re-executes each combinator's code once in a "dry run"
sandbox (`set_output`/`print` are no-ops, `entity`/`tick`/`red`/`green` are
stubbed) purely so that any `script.on_event(...)` calls at the top of the
user's code re-populate the dispatch tables.

### 3.3 Execution engine (Section 2)
`build_sandbox(entity, data, tick)` constructs the per-execution
environment:

1. Reads the combinator's **red** and **green** input networks
   (`defines.wire_connector_id.combinator_input_red/green`) into two plain
   Lua tables, `{ [signal_name] = count }`.
2. Builds a `set_output(type, name, count)` closure that validates argument
   types, floors/defaults the count, silently **ignores zero-count calls**
   (so you don't need to manually "not set" unused signals), and appends to
   a local `pending_outputs` accumulator.
3. Builds a `print(...)` closure that concatenates arguments and calls
   `game.print` with a teal color — visible to every player in chat.
4. Assembles the final `sandbox` table — this **is** the full API surface
   available to user code (see §3.5 below) — and sets `sandbox._ENV =
   sandbox` so that bare global reads/writes in the user's chunk resolve
   against this table instead of the real `_G`. This is the actual sandboxing
   mechanism: `load(code, chunkname, "t", sandbox)` compiles the chunk with
   `sandbox` as its environment, so the user script can never see or mutate
   real mod/game globals it wasn't explicitly given.

`apply_outputs(entity, pending_outputs, enabled)` then takes the
accumulated outputs and writes them onto the underlying
**decider-combinator** control behavior: it clears any previous
`parameters`, adds a condition that is unconditionally true (`{comparator =
"="}` compares the blank/no signal to itself — no real entity ever emits an
unnamed signal, so it's permanently `0 = 0`), and adds one
`add_output{... constant = count}` entry per queued signal. In effect, the
mod reuses the native decider-combinator's "always output constant" trick
to drive arbitrary circuit output from scripted logic.

`execute_code(entity, data, tick)` ties it together: builds the sandbox,
`load()`s the code, and **always runs inside `pcall`** — both compile
errors and runtime errors are caught, stringified via `safe_error_string`,
and stashed in `data.last_error` (shown in the GUI) rather than crashing the
mod or the save. On success, the sandbox's mutated `storage` table is
written back to `data.storage` so user-script state persists tick-to-tick
and across saves.

### 3.4 Global state & lifecycle (Sections 3–4)
Per-combinator state lives in `storage.combinators[unit_number]`:

```lua
storage.combinators[unit_number] = {
    entity, code, interval, storage,
    last_error, output_enabled, run_on_timer,
}
```

Standard Factorio entity-lifecycle events wire this up:
`on_built_entity` / `on_robot_built_entity` / `script_raised_built` /
`script_raised_revive` → `register_combinator` (fresh default state, 20-tick
interval); `on_player_mined_entity` / `on_robot_mined_entity` /
`on_entity_died` / `script_raised_destroy` → `unregister_combinator`;
`on_entity_cloned` → copies `code`/`interval`/`output_enabled`/`run_on_timer`
from source to destination but **deliberately does not copy `storage`**, so
every cloned combinator (e.g. via blueprint/robot construction or mod
cloning) starts with a clean persistent-state slate while keeping the same
logic.

### 3.5 Main tick handler (Section 5)
On every `on_tick`, the mod iterates all registered combinators and runs
`execute_code` only for those whose entity is still valid, that have
non-empty code, have `run_on_timer ~= false`, and where
`tick % data.interval == 0`. This is the "Timer" toggle mentioned in the
GUI: unchecking it turns a combinator into a **purely event-driven** script
that only reacts to `script.on_event`/`on_nth_tick` registrations instead of
running on a fixed cadence. Every 20 ticks it also refreshes the live
signal-monitor labels for any open GUI.

### 3.6 GUI (Section 6)
A screen-anchored frame (`lua-combinator-gui`) per open player provides: a
multi-line code text box, live red/green signal monitors, an interval
field, "Timer enabled" / "Output enabled" checkboxes, and an "Apply" button
that saves `code` into `storage.combinators[...]` and re-runs
`run_setup_pass` so event registrations take effect immediately. New
combinators default to a generously commented example script (embedded as
`EXAMPLE_CODE`) that doubles as inline documentation — explaining `red`,
`green`, `tick`, `set_output`, `storage`, events, and the Timer toggle
directly in the editor the first time a player opens one.

### 3.7 The sandbox API, summarized

Every combinator script executes with this environment:

| Name | Type | Description |
|---|---|---|
| `tick` | number | Current game tick at execution time. |
| `red` / `green` | table | `{ [signal_name] = count }` read from the input red/green wires. |
| `entity` | `LuaEntity` | The combinator entity itself (for `get_circuit_network`, `surface`, `position`, etc.). |
| `set_output(type, name, count)` | function | Queues an output signal (`type` ∈ `"item"`\|`"fluid"`\|`"virtual"`). Zero counts are a no-op. |
| `print(...)` | function | Sends a chat message to all players, teal-colored. |
| `storage` | table | Persistent per-combinator table; survives ticks, saves, and reloads (not clones). |
| `script.on_event` / `on_nth_tick` / `on_init` / `on_load` | functions | Safe, multiplexed subset of the real `script` API. |
| `game`, `defines`, `remote`, `rendering`, `prototypes` | — | Direct, unrestricted access to these Factorio runtime globals. |
| `math`, `table`, `string`, `pairs`, `ipairs`, `next`, `select`, `type`, `tostring`, `tonumber`, `pcall`, `xpcall`, `error`, `assert`, `rawget`, `rawset`, `rawequal`, `rawlen`, `setmetatable`, `getmetatable`, `unpack` | — | Standard Lua building blocks. Notably **absent**: `io`, `os`, `require`, `load`/`loadstring`, `debug` — the usual suspects for sandbox escapes. |

Because `game`, `rendering`, and the full entity API are exposed
unrestricted, this is a **trusted-author sandbox** (it stops accidental
desyncs and crashes via `pcall`/deterministic errors, and stops reads of
raw memory addresses) rather than a security sandbox against a malicious
player — appropriate for a singleplayer/co-op mod where all players are
assumed to trust each other's pasted code.

---

## 4. The bundled examples

| File | Purpose | Interval |
|---|---|---|
| [example.lua](/c:/Users/Admin/Desktop/LuaCode/lua-combinator/examples/example.lua) | Iron-plate stock monitor with hysteresis-free threshold alerting and throttled chat alerts. | 60 ticks |
| [example_reactor_monitor.lua](/c:/Users/Admin/Desktop/LuaCode/lua-combinator/examples/example_reactor_monitor.lua) | Reactor/heat-exchanger temperature monitor using a **hysteresis state machine** (`storage.enabled`) to avoid relay chatter near the threshold; includes a commented-out "direct API" variant that reads temperature without any circuit wiring. | 20 ticks |
| [example_output_network_controller.lua](/c:/Users/Admin/Desktop/LuaCode/lua-combinator/examples/example_output_network_controller.lua) | Earlier/alternate revision of the rocket monitor below — scans wired rocket silos and drives lamps/speakers/a requester chest on the output network. | 60 ticks |
| [example_rocket_monitor.lua](/c:/Users/Admin/Desktop/LuaCode/lua-combinator/examples/example_rocket_monitor.lua) | The most feature-complete example: rocket-silo readiness aggregation **and** automatic Vulcanus payload-request management. Reviewed in full below. | 60 ticks |

`example_output_network_controller.lua` and `example_rocket_monitor.lua`
are near-duplicates — the latter is clearly the newer iteration (it adds
surface-aware chest clearing, simplifies the output-network membership
check, and fixes a couple of rough edges — see §5.6). Keeping both in the
repo is slightly redundant; consolidating or clearly marking one as
deprecated/legacy would reduce confusion for anyone browsing the examples
folder.

---

## 5. Deep dive: `examples/example_rocket_monitor.lua`

This script turns the Lua Combinator into a **two-way rocket-silo
automation controller**: it reads readiness state from one or more rocket
silos over the input (red) wire, and — on the output (red) wire — drives
lamps, a programmable speaker, and a Factorio 2.0 **requester chest** that
automatically orders mining-drill payloads for Vulcanus rocket launches.

### 5.1 Header comment — the wiring contract

```lua
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
```

This isn't just decorative — it's the script's informal "interface
specification," documenting exactly which physical wire goes where and
what each output virtual signal means, since none of that is otherwise
discoverable from the code alone once pasted into the in-game editor.
`signal-G`/`signal-Y`/`signal-R`/`signal-T` correspond to the vanilla
virtual signals for **G**reen, **Y**ellow, **R**ed-letter, and **T**-letter
(used generically here, not tied to wire color).

### 5.2 Guard clause

```lua
if not entity then return end
```

`entity` is only `nil` during the dry "setup pass" (`run_setup_pass`, see
§3.2/§3.3) used purely to re-register event handlers after a load. Since
this script has no `script.on_event`/`on_nth_tick` registrations at all —
it is a pure polling script driven entirely by the Timer interval — this
guard simply ensures none of the real logic (which assumes a valid
`entity`) executes during that stubbed dry run.

### 5.3 Configuration block

```lua
local PAYLOAD_ITEM   = "big-mining-drill"  -- item name to request
local PAYLOAD_COUNT  = 20                  -- how many to request
local PAYLOAD_SLOT   = 1                   -- chest slot to use
```

Simple named constants up top, the standard pattern used across all four
examples — makes the script easy to re-target at a different payload item
or quantity without hunting through the logic body.

### 5.4 Scanning the input network for rocket silos

```lua
local in_net = entity.get_circuit_network(
    defines.wire_connector_id.combinator_input_red)

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
        ...
```

Key design points:

- **It doesn't just trust the raw signal values on the wire** — a rocket
  silo's own circuit output only reports things like rocket-parts count or
  launch status *as configured on the silo itself*, and multiple silos on
  the same wire would have their signals summed together, losing
  per-silo identity. Instead the script calls
  `entity.surface.find_entities_filtered{name = "rocket-silo", force =
  entity.force}` to get **direct handles** to every rocket silo belonging
  to the combinator's force on the same surface, then inspects each one's
  real properties (`.rocket_parts`, `.rocket_silo_status`) through the
  Factorio API rather than through circuit signals. This sidesteps signal
  aggregation entirely and gives exact per-silo state.
- `if silo.rocket_parts == nil then goto next_silo end` filters out any
  "rocket-silo"-named entity that isn't actually a functional silo (this
  field is `nil` for, e.g., silos in a state where the property doesn't
  apply — a defensive null-check before touching silo-specific fields).
- **Connectivity check** — since `find_entities_filtered` returns *every*
  silo on the surface regardless of wiring, the script must separately
  confirm each candidate silo is actually hooked to the *same* circuit
  network as the combinator's input:

  ```lua
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
  ```

  The comment clarifies *why* `circuit_red`/`circuit_green` are used here
  instead of `combinator_input_red`: **rocket silos are not combinators**,
  so they expose their wire connectors under the generic
  `circuit_red`/`circuit_green` connector ids rather than the
  combinator-specific `combinator_input_*` / `combinator_output_*` ids.
  Matching by `network_id` (not entity identity or wire color) is the
  correct way to test "is this entity electrically part of the same
  network as my input wire," since the same logical network can be
  reached through red or green copper depending on topology.
- **Tallying status**: for every silo confirmed connected,
  `silos_total` increments, and then:

  ```lua
  if silo.rocket_silo_status == defines.rocket_silo_status.rocket_ready then
      silos_ready = silos_ready + 1
  else
      silos_building = silos_building + 1
  end
  ```

  using the `defines.rocket_silo_status` enum (Factorio 2.0 API) rather
  than inferring readiness from circuit signals — again, exact and
  unambiguous.
- **`goto`/labels for early-continue**: Lua has no `continue` statement, so
  the idiomatic workaround — `goto next_silo` jumping to a trailing
  `::next_silo::` label at the loop body's end — is used three times to
  skip invalid/unwired silos without deeply nesting the rest of the loop
  body in `if` blocks. This is standard, idiomatic Lua 5.2+ style (and
  Factorio's Lua runtime supports `goto`).

### 5.5 Deriving aggregate status

```lua
local all_ready = silos_total > 0 and silos_ready == silos_total
local any_ready = silos_ready > 0
local building  = silos_building > 0 or (any_ready and not all_ready)
```

Three boolean flags computed purely from the tallies above:
- `all_ready` guards against the vacuous-truth trap — with zero silos
  wired, `silos_ready == silos_total` (`0 == 0`) would otherwise be `true`;
  the explicit `silos_total > 0 and ...` prevents an empty network from
  falsely reporting "all ready."
- `any_ready` is a simple existence check, used to light lamps as soon as
  *any* progress is made.
- `building` is slightly redundant-looking but intentional: it's `true`
  either when silos are explicitly still building, **or** (belt-and-braces)
  when some but not all are ready — covering any inconsistent in-between
  state.

### 5.6 Emitting circuit output signals

```lua
set_output("virtual", "signal-green",  all_ready and 1 or 0)
set_output("virtual", "signal-yellow", building  and 1 or 0)
set_output("virtual", "signal-R",      silos_ready)
set_output("virtual", "signal-T",      silos_total)
```

Straightforward use of the sandbox's `set_output` API (§3.7). Recall that
`set_output` silently drops zero-count calls — but here `0` is passed
*explicitly* via the ternary-style `and/or` idiom specifically so that
`signal-green`/`signal-yellow` are forced to `0` (cleared) rather than
simply omitted when false, which matters because `set_output`'s "zero is a
no-op" optimization only prevents *adding new* zero outputs — it doesn't
retract a previously-true signal. Since `apply_outputs` (§3.3) clears all
parameters before re-adding the current tick's outputs, in practice this
explicit `0` vs. omission distinction doesn't change final wire state here
(the whole output set is replaced every tick) — but it does keep the
intent of "always drive these two indicator signals" explicit and
future-proof against caching behavior changes.

One naming note: the header comment documents `signal-G`/`signal-Y`, but
the code actually emits `signal-green`/`signal-yellow` — the comment is
slightly out of sync with the implementation (a minor documentation
inconsistency worth fixing if this script is revised).

### 5.7 Scanning the output network and area

```lua
local out_net = entity.get_circuit_network(
    defines.wire_connector_id.combinator_output_red)
if not out_net then return end

local out_id = out_net.network_id
local area   = {
    { entity.position.x - 64, entity.position.y - 64 },
    { entity.position.x + 64, entity.position.y + 64 },
}

for _, ent in pairs(entity.surface.find_entities_filtered{ area = area }) do
```

If nothing is connected to the output (red) wire, the script bails out
early — there's nothing to control. Otherwise it defines a 128×128-tile
bounding box centered on the combinator and asks the surface for every
entity inside it. This is a **spatial pre-filter**: rather than scanning
the whole surface for lamps/speakers/chests, it only looks nearby (lamps,
speakers, and requester chests wired to this combinator are assumed to be
placed physically close to it — a reasonable assumption for typical base
layouts, and one that keeps `find_entities_filtered` cheap).

### 5.8 Per-entity filtering and output-network membership check

```lua
for _, ent in pairs(entity.surface.find_entities_filtered{ area = area }) do
    if not ent.valid  then goto skip end
    if ent.surface.name == "nauvis" then goto skip end
    if ent == entity  then goto skip end

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
```

Walking through each guard:
- `ent.valid` — standard defensive check; entities can become invalid
  between the `find_entities_filtered` call and use (though unlikely
  within a single synchronous script tick, it's cheap insurance).
- `ent.surface.name == "nauvis"` — **this is the "payload requests are
  cleared on other surfaces" rule from the header comment**, implemented
  here as a skip: anything physically on Nauvis is ignored entirely by this
  loop (so a requester chest on Nauvis is never touched/configured by this
  script — relevant because `big-mining-drill` payload requests are a
  Vulcanus-specific concern per the header comment).
- `ent == entity` — don't try to treat the combinator itself as a
  controllable target.
- The output-network membership check only tests
  `defines.wire_connector_id.circuit_red` — i.e. it assumes lamps,
  speakers, and the requester chest are wired with **red wire only** to
  the combinator's output. This matches the header's "OUTPUT wire (bottom)"
  singular-wire wiring diagram.
- **Bug/smell**: `net.network_id == 947` is a **hard-coded magic number**
  rather than `out_id` (the combinator's own `out_net.network_id` computed
  just above at line `local out_id = out_net.network_id`). `out_id` is
  computed but then **never used** — this looks like a leftover debug
  value from a specific in-progress game session's network, and as written
  the script will **only ever correctly recognize output-network members
  if that specific save happens to have circuit network id `947`**, which
  is essentially never true in a fresh game. This is very likely a bug
  introduced by accidental find-and-replace or by copying from a specific
  debugging session. **Fix**: replace `net.network_id == 947` with
  `net.network_id == out_id`. (Note `example_output_network_controller.lua`
  gets this right — it compares against `out_id` — so this does look like a
  regression unique to `example_rocket_monitor.lua`.)

Also note: unlike `example_output_network_controller.lua`, this script's
membership check only tries `circuit_red`, not the fuller set of
`combinator_output_red/green` + `circuit_red/green` tried in the other
example — so if the lamp/speaker/chest for some reason is wired with green
wire instead, this version would miss it. That's consistent with the
documented single-red-wire layout, but makes it slightly less robust than
its sibling script.

### 5.9 Acquiring a control behavior safely

```lua
local ok_cb, cb = pcall(function()
    return ent.get_or_create_control_behavior()
end)
if not (ok_cb and cb) then goto skip end
```

`get_or_create_control_behavior()` can throw for entity types that don't
support control behaviors at all; wrapping it in `pcall` turns a potential
hard runtime error (which would abort the whole tick's execution for this
combinator, per `execute_code`'s outer `pcall` in §3.3) into a graceful
skip for that one entity.

### 5.10 Driving a lamp

```lua
if ent.type == "lamp" then
    -- Light up as soon as any rocket is ready
    pcall(function() cb.enabled = any_ready end)
```

Sets the lamp's `LuaControlBehavior.enabled` directly from script — this
is a more direct alternative to the usual "wire a lamp with a circuit
condition" approach; the lamp's own circuit-condition configuration is
bypassed entirely since the script is driving `enabled` as a boolean flag
straight from game logic.

### 5.11 Driving a programmable speaker

```lua
elseif ent.type == "programmable-speaker" then
    -- Sound the alert only when every wired silo is ready
    pcall(function()
        cb.circuit_enable_disable = true
        cb.enabled = all_ready
    end)
```

Two fields are set: `circuit_enable_disable = true` tells the speaker to
actually respect circuit-driven enable/disable (speakers default to
*always* playing otherwise), and `enabled = all_ready` is the actual
gate — the speaker only sounds once **every** wired silo (not just one) is
ready, a stricter bar than the lamp's "any ready" trigger. This creates a
nice two-tier UX: lamp = "progress is happening," speaker = "fully ready,
go."

### 5.12 Driving the Vulcanus requester chest

```lua
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
```

This is the most functionally interesting — and most clearly **buggy** —
block in the file, so it's worth examining carefully. (I verified the
analysis below by extracting the exact control-flow shape into a
standalone snippet and compiling/running it against a real Lua 5.x
runtime — see the note at the end of this subsection.)

**Intent** (per the header comment): always keep the chest requesting
`PAYLOAD_COUNT` of `PAYLOAD_ITEM` (the "always request on Vulcanus"
behavior described at the top — note this differs slightly from
`example_output_network_controller.lua`, which only requests when
`all_ready` and clears otherwise; this script's header says the request
should be continuous on Vulcanus and only cleared "on other surfaces,"
which is already handled by the earlier `ent.surface.name == "nauvis"`
skip in §5.8).

**What it correctly does**:
- `ent.get_logistic_sections()` — the Factorio 2.0 API for configuring a
  requester/logistic chest's requests, replacing the older
  `request_slot`-array API. `LuaLogisticSections` represents the group of
  request "sections" a chest can have.
- `ls.get_section(1)` / `ls.add_section()` — fetches the first logistic
  section, creating one if the chest has none yet (a freshly placed chest
  starts with zero sections).
- `section.set_slot(slot, {value = {...}, min = ..., max = ...})` — the
  correct 2.0 call shape for writing a manual logistic request into a
  specific slot, including the now-mandatory `quality` field on the
  `value` table.

**The bug**: the `if/else` here *looks* malformed, but it is actually
**valid, compilable Lua** — just not the Lua the author intended. The
critical detail is that `if <cond> then goto skip end` is itself a
complete, self-contained if-statement:

```lua
if not (section and section.valid and section.is_manual) then goto skip end
    section.set_slot(PAYLOAD_SLOT, { ... })
else
    section.clear_slot(PAYLOAD_SLOT)
end
```

The `end` right after `goto skip` closes *that* if-statement immediately.
The indented `section.set_slot(...)` call on the next line is therefore
just an ordinary statement that runs **unconditionally** once a valid
manual section exists (indentation is cosmetic in Lua — it does not nest
the call inside the preceding `if`). The real surprise is the `else` that
follows: since the small `if...then goto skip end` has already closed,
there is no open `if` left for this `else` to attach to **at this nesting
level** — but the *outer* `if ent.type == "lamp" then … elseif
ent.type == "programmable-speaker" then … elseif ent.name ==
"requester-chest" then …` entity-type dispatch (§5.10–§5.12) is still
open, because its own closing `end` hasn't been reached yet. Lua's parser
resolves the dangling `else` by attaching it to that outer dispatch
instead, turning it into a silent catch-all `else` branch for **any
circuit-connected entity in the output area that is not a lamp, not a
programmable speaker, and not named `"requester-chest"`**. The `end`
right after `section.clear_slot(PAYLOAD_SLOT)` then closes that outer
dispatch, and the file's token count balances out exactly — which is why
it compiles cleanly despite reading like a syntax error.

That reclassification has a serious consequence: `section` was declared
with `local` *inside* the `requester-chest` branch, so it is **out of
scope** inside this reattached `else` branch. Referencing `section.​clear_slot(...)`
there resolves `section` as an undeclared global (`nil`), so the moment
any qualifying "other" entity is found on the output network, the script
throws a runtime error — `attempt to index a nil value (global
'section')` — instead of silently doing nothing. Because this call sits
outside any of the `pcall` wrappers used elsewhere in the loop (§5.9–§5.11
wrap their control-behavior mutations in `pcall`; this one doesn't), the
error is not contained to that one entity. It propagates out of the whole
chunk and is only caught by `execute_code`'s outer `pcall` (§3.3) — which
means the **entire script aborts for that tick**, `data.last_error` is set
to `"Runtime: attempt to index a nil value (global 'section')"`, and
`apply_outputs` is never reached, so **none** of the `signal-green` /
`signal-yellow` / `signal-R` / `signal-T` outputs computed earlier in the
script (§5.6) get written to the combinator that tick either.

Whether this actually fires depends on what else shares the output
circuit network: if only lamps, speakers, and the requester chest are
wired to it (the documented layout), the bug stays latent. But the moment
any other circuit-connected entity — another pole, inserter, combinator,
etc. — shares that same network, every tick hits the broken `else` branch
and the combinator's outputs stop updating entirely.

**Suggested fix** — the author's intent was almost certainly:

```lua
elseif ent.name == "requester-chest" then
    local ls = ent.get_logistic_sections()
    if not ls then goto skip end

    local section = ls.get_section(1)
    if not section then section = ls.add_section() end
    if not (section and section.valid and section.is_manual) then goto skip end

    section.set_slot(PAYLOAD_SLOT, {
        value = { type = "item", name = PAYLOAD_ITEM, quality = "normal" },
        min = PAYLOAD_COUNT, max = PAYLOAD_COUNT,
    })
```

i.e. drop the stray `else … end` entirely and simply always set the slot
once a valid manual section is found — which matches the header comment's
"continuously requests" wording and removes the dangling-else hazard. (If
the intent was instead to mirror `example_output_network_controller.lua`'s
conditional request/clear behavior, the condition should test `all_ready`
rather than being an always-true fallthrough — but combined with the
`nauvis` skip already filtering out off-Vulcanus chests, an unconditional
"always request" reading is more consistent with this file's own header
comment.)

> **Verification note:** I confirmed this behavior empirically rather than
> relying purely on manual grammar tracing — I reproduced the exact
> nesting shape (the surrounding `for` loop, the three-way `if
> ent.type==lamp / elseif .../ elseif ent.name=="requester-chest"`
> dispatch, the two early `if...then goto skip end` statements, and the
> disputed `if/else/end`) in an isolated snippet and ran it through a real
> Lua 5.x engine. It compiled without error, and calling it with a
> stand-in entity that matches none of the three branches executed the
> reattached `else` clause and resolved its `section` reference as `nil`
> (printing `"clear:nil"` in the test rather than throwing at parse time) —
> exactly as predicted above.

### 5.13 Summary of findings for this file

| # | Severity | Location | Issue |
|---|---|---|---|
| 1 | 🟠 High | §5.12, requester-chest branch | A dangling `else` after the self-closing `if not (...) then goto skip end` silently reattaches to the outer `ent.type`/`ent.name` dispatch instead of causing a parse error. It compiles fine, but turns into a hidden catch-all branch that calls `section.clear_slot(...)` with `section` out of scope (resolving to `nil`) for any non-lamp/speaker/chest entity sharing the output network — throwing an uncaught `attempt to index a nil value (global 'section')` that aborts the whole tick's output. |
| 2 | 🟠 High | §5.8, output-network check | `net.network_id == 947` hard-codes a magic network id instead of comparing to the already-computed `out_id` — the output-network membership check will fail on virtually any real save. |
| 3 | ⚪ Low | §5.6 vs. header | Header comment documents `signal-G`/`signal-Y`; code emits `signal-green`/`signal-yellow`. Cosmetic inconsistency only. |
| 4 | ⚪ Low | §4 | `example_output_network_controller.lua` and `example_rocket_monitor.lua` are near-duplicate scripts; worth consolidating or labeling one as superseded. |

Neither bug prevents the script from loading — it compiles and will
appear to work in the simplest wiring layouts. That makes issue #1
particularly easy to miss during testing: it only manifests once a
"stray" circuit-connected entity shares the output network, at which
point the combinator silently stops updating any of its outputs and
reports a cryptic runtime error. Both issues are mechanical, low-effort
fixes (see the suggested patches in §5.8 and §5.12); the surrounding
**design** of the script — direct API querying of silo state instead of
trusting aggregated circuit signals, careful network-membership checks,
`pcall`-wrapped control-behavior access, and correct use of the Factorio
2.0 `LuaLogisticSections` API — is solid and demonstrates the Lua
Combinator's capabilities well once the two fixes above are applied.

---

## 6. Overall assessment

**Strengths**
- Clean, well-commented, section-numbered `control.lua` with a genuinely
  careful sandboxing approach (`_ENV` substitution, curated whitelist of
  stdlib functions, no `io`/`os`/`load`/`debug` leakage).
- Thoughtful handling of Factorio-specific correctness hazards: multiplayer
  determinism in error formatting (`safe_error_string`), closure
  non-serializability (`run_setup_pass` re-registration on every load),
  and the single-handler-per-event limitation (the custom dispatch-table
  multiplexer).
- `data.lua`'s deep-copy-and-retint approach to the entity prototype is a
  low-maintenance way to stay visually/behaviorally in sync with the
  vanilla decider-combinator.
- Example scripts are genuinely instructive, each demonstrating a distinct
  pattern (threshold alerting, hysteresis, direct-entity-API control,
  multi-entity output-network orchestration).

**Issues found**
- `examples/example_rocket_monitor.lua` compiles and loads, but has a
  dangling-`else` control-flow bug that silently reattaches to the wrong
  `if`-chain (causing an uncaught `nil`-index runtime error on certain
  wiring layouts) and a hard-coded magic network id that would prevent
  the output-network control logic from working as shipped (see §5.12
  and §5.8 for exact fixes).
- Minor documentation drift (`signal-G` vs. `signal-green`) and
  duplication between the two rocket-monitor example variants.

None of the issues above touch `control.lua`/`data.lua` (the actual mod
runtime) — they are confined to the example script content, so the mod
itself is unaffected; only the example would need correcting for players
who paste it as-is.
