# Lua Combinator — Scripting API Reference

This is the complete reference for the sandboxed Lua environment every
Lua Combinator entity executes its code in. For an explanation of *how*
the sandbox and runtime are implemented, see the "control.lua — the
runtime engine" section of [README.md](./README.md); this document only
covers the functions and values available to **your scripts**.

The in-game code editor also embeds a condensed quick-reference as the
default example text — this file is the full version of that, with every
function, its signature, and worked examples.

---

## 1. Inputs

| Name | Type | Description |
|---|---|---|
| `tick` | `number` | Current game tick at execution time. |
| `red` | `table` | `{ [signal_name] = count }` read from the red input wire. |
| `green` | `table` | `{ [signal_name] = count }` read from the green input wire. |
| `entity` | `LuaEntity` | The combinator entity itself (`entity.surface`, `entity.position`, `entity.get_circuit_network(...)`, etc.). |
| `get_signal(name [, color])` | `function` | Reads a signal's value. See below. |
| `get_network(color [, side])` | `function` | Returns the raw `LuaCircuitNetwork` for a wire. See below. |

### `get_signal(name [, color])`

Shorthand for reading `red`/`green` without writing `(red[name] or 0)`
everywhere.

- `get_signal(name)` — returns `(red[name] or 0) + (green[name] or 0)`,
  i.e. what the combinator would see if both wires fed a single input
  (matches how vanilla combinators merge same-named signals from both
  wires).
- `get_signal(name, "red")` — just the red wire's value (`0` if absent).
- `get_signal(name, "green")` — just the green wire's value (`0` if absent).

```lua
local iron = get_signal("iron-plate")        -- red + green combined
local iron_red_only = get_signal("iron-plate", "red")
```

### `get_network(color [, side])`

Returns the live `LuaCircuitNetwork` object for a wire, without needing to
remember the `defines.wire_connector_id.*` constant names. Useful when you
need more than a signal count — e.g. `network.network_id`, iterating
`network.signals` directly, or walking the entities connected to it.

- `color` — `"red"` or `"green"` (required).
- `side` — `"input"` (default) or `"output"`.

```lua
local in_red   = get_network("red")              -- same as combinator_input_red
local out_green = get_network("green", "output") -- same as combinator_output_green

if in_red then
    print("red network id:", in_red.network_id)
end
```

Returns `nil` if nothing is connected to that wire/side, exactly like
calling `entity.get_circuit_network(...)` directly would.

---

## 2. Outputs

| Name | Type | Description |
|---|---|---|
| `set_output(type, name, count)` | `function` | Queues an output signal. |
| `clear_output()` | `function` | Discards everything queued so far this execution. |

### `set_output(type, name, count)`

- `type` — `"item"`, `"fluid"`, or `"virtual"`.
- `name` — signal name string (e.g. `"iron-plate"`, `"water"`, `"signal-A"`).
- `count` — integer; non-integers are floored. **A count of `0` is a
  silent no-op** — you don't need to manually skip unused signals.

```lua
set_output("item", "iron-plate", 42)
set_output("virtual", "signal-A", get_signal("copper-plate"))
```

### `clear_output()`

Cancels every `set_output` call made so far in the current execution. Handy
when later logic in the same script needs to override an earlier
decision instead of layering more `set_output` calls on top:

```lua
set_output("virtual", "signal-A", 1)
if some_condition then
    clear_output()              -- scrap the signal-A output above
    set_output("virtual", "signal-B", 1)
end
```

---

## 3. Debugging & logging

| Name | Type | Description |
|---|---|---|
| `print(...)` | `function` | Sends a chat message to all players (teal-colored). |
| `dump(...)` | `function` | Like `print(...)`, but table arguments are pretty-printed instead of showing as raw addresses. |
| `log(...)` | `function` | Writes to the log file (`factorio-current.log`) instead of chat — quieter, and works during `on_load`. |
| `inspect(value)` | `function` | Returns a deterministic, human-readable string for any value, including nested tables. |

```lua
print("iron:", get_signal("iron-plate"))      -- chat, scalars only look right
dump("iron signal row:", red)                 -- chat, table printed nicely
log("tick", tick, "storage:", storage)        -- log file only, not chat
local s = inspect(storage)                    -- get the string yourself
```

`inspect`/`dump`/`log` all serialize tables with `serpent` under the hood
(sorted keys, no raw memory addresses), so output is stable across
machines/players — safe to use even for values that might end up compared
in a multiplayer game.

---

## 4. Math helpers

| Name | Type | Description |
|---|---|---|
| `clamp(value, min, max)` | `function` | Clamps `value` into `[min, max]`. Either bound may be `nil` to leave that side unclamped. |
| `round(value [, decimals])` | `function` | Rounds `value` to `decimals` decimal places (default `0`). |

```lua
local pct = clamp(get_signal("signal-P"), 0, 100)
local half = round(pct / 2)          -- rounds to nearest integer
local precise = round(pct / 3, 2)    -- rounds to 2 decimal places
```

---

## 5. Persistent state

| Name | Type | Description |
|---|---|---|
| `storage` | `table` | Persistent per-combinator table. Survives ticks and game saves/loads. **Not** copied when a combinator is cloned/blueprinted — each new entity starts with an empty `storage`. |

```lua
storage.count = (storage.count or 0) + 1
set_output("virtual", "signal-C", storage.count)
```

---

## 6. Events

| Name | Type | Description |
|---|---|---|
| `script.on_event(event_id_or_ids, handler)` | `function` | Registers a handler for one or more Factorio events. |
| `script.on_nth_tick(n, handler)` | `function` | Registers a handler that fires every `n` ticks. |
| `script.on_init(handler)` / `script.on_load(handler)` | `function` | Run `handler` immediately (combinator code is itself re-run on every load, so this is just for parity with the real API). |

Handlers are automatically re-registered on every game load, so they don't
need to be saved/restored manually. Uncheck **Timer** in the GUI if you
want a combinator to run *only* via event handlers rather than on a fixed
tick interval.

```lua
script.on_event(defines.events.on_player_joined_game, function(e)
    local name = game.players[e.player_index].name
    print("Welcome, " .. name .. "!")
end)

script.on_nth_tick(300, function(e)
    local force = game.forces["player"]
    set_output("virtual", "signal-R", force.rockets_launched)
end)
```

---

## 7. Factorio runtime access (unrestricted)

| Name | Description |
|---|---|
| `game` | `LuaGameScript` — `game.players`, `game.surfaces`, `game.forces`, etc. |
| `defines` | All Factorio enums (`defines.events`, `defines.direction`, `defines.wire_connector_id`, ...). |
| `remote` | Mod interfaces (`remote.call(...)`). |
| `rendering` | In-world drawing API. |
| `prototypes` | Prototype data lookups. |

These are exposed **unrestricted** — this is a *trusted-author* sandbox
(it prevents accidental crashes/desyncs via `pcall` and deterministic
errors), not a security sandbox against untrusted/malicious players.

---

## 8. Standard Lua building blocks

```
math  table  string
pairs  ipairs  next  select  type  tostring  tonumber
pcall  xpcall  error  assert
rawget  rawset  rawequal  rawlen
setmetatable  getmetatable  unpack
```

Notably **absent**: `io`, `os`, `require`, `load`/`loadstring`, `debug` —
the usual sandbox-escape vectors.

---

## 9. Full worked example

```lua
-- Merge iron-plate across both wires, clamp it, forward it, and log it.
local iron = clamp(get_signal("iron-plate"), 0, 2000)

storage.peak = math.max(storage.peak or 0, iron)

if iron > 0 then
    set_output("item", "iron-plate", iron)
else
    clear_output()
end

log("iron now:", iron, "peak:", storage.peak)

script.on_nth_tick(600, function()
    print("Iron peak so far:", storage.peak)
end)
```

---

See the [examples/](./examples) folder for complete, runnable combinator
scripts (stock monitors, reactor temperature alerting, rocket-silo
orchestration), and [README.md](./README.md) for a deep dive into how the
runtime itself is implemented.
