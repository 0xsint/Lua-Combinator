# Lua Combinator — Scripting API Reference

Everything a combinator script can use. The in-game **Help** tab is a
condensed version of this page; [EXAMPLES.md](./EXAMPLES.md) lists the 40+
example scripts that ship with the mod.

- [1. How a script runs](#1-how-a-script-runs)
- [2. Inputs](#2-inputs)
- [3. Outputs](#3-outputs)
- [4. State](#4-state)
- [5. State helpers](#5-state-helpers)
- [6. Talking to players](#6-talking-to-players)
- [7. Events](#7-events)
- [8. Utilities](#8-utilities)
- [9. Factorio API and standard library](#9-factorio-api-and-standard-library)
- [10. Remote interface](#10-remote-interface)

---

## 1. How a script runs

A combinator runs its code in one of three ways:

| Mode | When | Outputs |
|---|---|---|
| **Timer run** | Every *N* ticks while **Timer** is checked (on ticks divisible by *N*), and on **Apply** / **Run Now**. | Rebuilt from scratch: whatever the script sets is the new output. |
| **Event handler** | When an event registered with `script.on_event` / `script.on_nth_tick` fires. | Starts from the current output. Only written back if the handler changed it. |
| **Registration pass** | On **Apply** and every time the save is loaded. | None. Registers event handlers only (see [§7](#7-events)). |

Every timer run gets a fresh global environment: a global variable set in
one run is gone in the next. Keep anything that must survive in
[`storage`](#4-state). (This is what keeps multiplayer in sync — a player who
just joined could not see state that is not saved.)

Errors never stop the game. The message, with the line number, appears in
the editor, a warning icon is drawn over the combinator, and the previous
output stays on the wire. A per-map setting can also announce errors in chat.

---

## 2. Inputs

| Name | Description |
|---|---|
| `red`, `green` | `{ [key] = count }` for each input wire. |
| `get_signal(key [, color])` | Red + green, or just `"red"` / `"green"`. Missing signals are `0`. |
| `signals([color [, side]])` | Sorted list of `{type, name, quality, count}`. `color` `nil` merges both wires; `side` is `"input"` (default) or `"output"`. |
| `get_output_signal(key [, color])` | Like `get_signal`, for the combinator's **output** wires (as of the start of this run). |
| `get_network(color [, side])` | The raw `LuaCircuitNetwork` for a wire, or `nil`. |
| `tick` | Current game tick. |
| `entity` | This combinator's `LuaEntity`. |
| `unit_number` | This combinator's unit number (unique id). |

**Keys.** A signal's key is its name for normal quality (`"iron-plate"`)
and `"name@quality"` otherwise (`"iron-plate@rare"`). Keys work everywhere a
name is accepted: `red["iron-plate@rare"]`, `get_signal("iron-plate@rare")`,
`out("iron-plate@rare", 5)`.

`red[key]` is `nil` for a missing signal while `get_signal` returns `0`;
use the table when you need to tell "absent" from "zero".

Inputs are read lazily — a script that never looks at them never pays for
reading the circuit network.

```lua
local iron = get_signal("iron-plate")             -- red + green
local only_red = get_signal("iron-plate", "red")

for _, s in ipairs(signals("red")) do              -- every red signal
    print(s.type, s.name, s.quality, s.count)
end
```

---

## 3. Outputs

| Name | Description |
|---|---|
| `out(key, count [, quality])` | Set an output; the signal type is worked out from the name. |
| `set_output(type, name, count [, quality])` | Set an output with an explicit type: `"item"`, `"fluid"`, `"virtual"`, `"entity"`, `"recipe"`, `"quality"`, `"space-location"`, `"asteroid-chunk"`. |
| `set_output(signal_id, count)` | Same, with a `{type =, name =, quality =}` table (type optional). |
| `add_output(...)` | Same arguments as `set_output`, but adds to what is already queued. |
| `set_outputs{ [key] = count, ... }` | Set many outputs at once. |
| `forward([color] [, filter])` | Copy input signals to the output. `filter(sig)` returns `false`/`nil` to drop, `true` to keep, or a number to replace the count. |
| `clear_output()` | Remove everything queued so far. |
| `get_outputs()` | `{ [key] = count }` of what is queued so far. |

- Setting a signal again **replaces** its value; use `add_output` to sum.
- A count of `0` removes the signal. Counts are floored to integers and
  clamped to the circuit network's 32-bit range.
- Unknown signals and the wildcards `signal-everything`, `signal-anything`
  and `signal-each` raise an error pointing at your line.
- The output is only written to the combinator when it actually changed, so
  a script that emits the same values every tick is cheap.
- The **Output enabled** checkbox blanks the output without discarding it.

```lua
out("iron-plate", 100)
set_output("virtual", "signal-A", 1)
set_output({type = "item", name = "copper-plate", quality = "rare"}, 5)
set_outputs{["steel-plate"] = 20, ["signal-B"] = 2}
forward("red", function(s) return s.type == "item" end)   -- items only
```

The mod also adds a virtual signal, `signal-lua-combinator`.

---

## 4. State

| Name | Description |
|---|---|
| `storage` | This combinator's persistent table. Survives saves. Not copied by blueprints, copy/paste or cloning. Cleared by **Reset storage**. |
| `shared` | One persistent table shared by **every** Lua Combinator in the save. |
| `transmit(channel, { [key] = count })` | Publish this combinator's values on a wireless channel (string or number). `transmit(channel, nil)` stops. |
| `receive(channel)` | `{ [key] = count }` summed over every transmitter on the channel, like a circuit network. |

Channels work across any distance and any surface. A transmitter that is
removed stops contributing automatically. Values are what each transmitter
last sent, so a receiver may see data from up to one interval ago.

```lua
-- outpost
transmit("outpost-1", {["iron-ore"] = get_signal("iron-ore")})
-- main base
set_outputs(receive("outpost-1"))
```

---

## 5. State helpers

These remember things between runs for you. The first argument is a key you
choose, so you can use each helper as often as you like. Their state is
stored per combinator (not in `storage`) and cleared by **Reset storage**.

| Helper | Returns |
|---|---|
| `rising_edge(key, cond)` | `true` on the run where `cond` turns true. |
| `falling_edge(key, cond)` | `true` on the run where `cond` turns false. |
| `changed(key, value)` | `true, old` when `value` differs from the previous call. |
| `hysteresis(key, value, low, high)` | `true` once `value >= high`, `false` once `value <= low`, unchanged in between. |
| `latch(key, set, reset)` | SR latch; reset wins. |
| `every(ticks)` / `every(key, ticks)` | `true` at most once per `ticks`. |
| `delay(key, cond, ticks)` | `true` once `cond` has been continuously true for `ticks`. |
| `average(key, value, samples)` | Moving average of the last `samples` values. |
| `ema(key, value, alpha)` | Exponential moving average (`alpha` 0–1, default 0.1). |
| `rate(key, value)` | Change of `value` per second since the previous call. |
| `pid(key, setpoint, measured, kp, ki, kd [, min, max])` | PID controller output, with anti-windup when clamped. |

```lua
local charge = get_signal("signal-A")
local backup = not hysteresis("charged", charge, 20, 80)
if rising_edge("backup", backup) then alert("Backup power on") end
out("signal-B", backup and 1 or 0)
```

---

## 6. Talking to players

| Name | Description |
|---|---|
| `print(...)` | Chat message to everyone. |
| `dump(...)` | Like `print`, tables pretty-printed. |
| `log(...)` | Write to `factorio-current.log` instead of chat. |
| `alert(message [, icon [, show_on_map]])` | Custom alert for the combinator's force, pointing at the combinator. `icon` is a signal name or SignalID. |
| `label(text [, {color, scale, offset}])` | Floating text above the combinator (rich text allowed). `label(nil)` removes it. |
| `rich_text(key)` / `rich_text(type, name [, quality])` | `"[item=iron-plate]"` style tag for chat and labels. |

```lua
if get_signal("iron-plate") < 50 then
    alert(rich_text("iron-plate") .. " is low", "iron-plate")
end
label(format_number(get_signal("iron-plate")) .. " plates")
```

Alerts need to be raised again while the condition lasts; calling `alert`
every run does exactly that.

---

## 7. Events

| Name | Description |
|---|---|
| `script.on_event(id_or_ids, fn)` | Run `fn(event)` when a Factorio event fires. `id_or_ids` may be a list. |
| `script.on_nth_tick(n, fn)` | Run `fn(event)` every `n` ticks. |
| `script.on_init(fn)` | Run `fn` once, with live data, when the code is applied. |
| `script.on_load(fn)` | Run `fn` during every registration pass (must not change anything). |

Handlers are registered during the **registration pass**, which runs your
top-level code with inert stand-ins on **Apply** and every time the save is
loaded. Because it must behave identically both times:

- `game`, `entity`, `rendering`, `prototypes`, `helpers` and `settings` are
  `nil` during registration, and inputs are empty,
- outputs, `print` and channel writes are ignored, and `storage` is a
  throwaway table,
- errors are ignored (they show up on the next real run instead).

So **register handlers at the top of the script**, before any code that
needs the game. Inside the handler everything is live: `entity`, `game`,
inputs, `storage`, outputs.

Uncheck **Timer** for scripts that should only react to events. Timer runs
and handlers can be combined: top-level code runs on the timer, handlers run
on their events.

The mod multiplexes events itself, so any number of combinators can listen
to the same event — including `on_tick` and the build/GUI events the mod
uses — without interfering. Handlers run in ascending `unit_number` order.

```lua
script.on_event(defines.events.on_rocket_launched, function(e)
    storage.launches = (storage.launches or 0) + 1
    out("signal-R", storage.launches)          -- edits the current output
end)

script.on_event({defines.events.on_built_entity, defines.events.on_robot_built_entity},
    function(e) storage.built = (storage.built or 0) + 1 end)

script.on_nth_tick(600, function()
    out("signal-T", entity.force.rockets_launched)
end)
```

---

## 8. Utilities

| Name | Description |
|---|---|
| `clamp(value, min, max)` | Either bound may be `nil`. |
| `round(value [, decimals])` | Round to `decimals` places (default 0). |
| `format_number(n [, decimals])` | `1234567` → `"1.23M"`. |
| `signal_type(key)` | `"item"`, `"fluid"`, `"virtual"`, … or `nil`. |
| `inspect(value)` | Deterministic, readable string for any value. |

---

## 9. Factorio API and standard library

`game`, `defines`, `prototypes`, `rendering`, `remote`, `helpers` and
`settings` are the real Factorio objects. Scripts can do anything a mod can
do with them — this is a *trusted-author* environment that protects the
game from crashes, not from deliberate misuse.

Standard Lua: `math`, `table`, `string`, `bit32`, `pairs`, `ipairs`, `next`,
`select`, `type`, `tostring`, `tonumber`, `pcall`, `xpcall`, `error`,
`assert`, `rawget`, `rawset`, `rawequal`, `rawlen`, `setmetatable`,
`getmetatable`, `unpack`, `table_size`.

Not available: `io`, `os`, `require`, `load`, `loadstring`, `debug`, and
any `script.*` function other than those in [§7](#7-events).

---

## 10. Remote interface

Other mods, scenarios and console commands can manage combinators through
`remote.call("lua-combinator", <function>, ...)`:

| Function | Description |
|---|---|
| `list()` | Sorted unit numbers of every Lua Combinator. |
| `get_code(unit)` / `get_config(unit)` | Code, or `{code, interval, run_on_timer, output_enabled}`. |
| `set_code(unit, code [, options])` | Apply code (and optional config fields) and run once. Returns the error or `nil`. |
| `run(unit)` | Run once now. Returns the error or `nil`. |
| `get_storage(unit)` / `set_storage(unit, table)` | Read or replace a combinator's `storage`. |
| `get_error(unit)` / `get_stats(unit)` | Last error; `{runs, events, errors, last_run}`. |
| `examples()` | `{id, category, title, description}` for every built-in example. |
| `load_example(unit, id)` | Apply a built-in example, e.g. `"basics.clock"`. |

```lua
/c for _, unit in pairs(remote.call("lua-combinator", "list")) do
     remote.call("lua-combinator", "load_example", unit, "world.day_night")
   end
```
