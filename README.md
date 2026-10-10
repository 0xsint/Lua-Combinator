# Lua Combinator

Lua Combinator is a Factorio 2.0 mod that adds a programmable circuit-network
combinator. Place it, open it, write Lua, and use the script to read circuit
inputs and drive circuit outputs.

The mod targets Factorio 2.0 and depends only on `base >= 2.0.0`; see
[`info.json`](./info.json).

## Using the combinator

1. Research **Lua Combinator** to unlock its recipe.
2. Place a Lua Combinator and connect its input/output circuit wires.
3. Open the entity to edit its Lua code.
4. Set the execution interval, or disable **Timer** to run only registered
   event handlers.
5. Select **Apply** to save the code, register its event handlers, and run it
   immediately. **Run Now** executes the current editor contents without
   waiting for the interval.

The editor also displays the red and green input signals, refreshed every
20 ticks, and any compile or runtime error from the last execution.

New combinators have these defaults:

| Setting | Default |
|---|---:|
| Timer interval | 20 ticks |
| Timer | Enabled |
| Circuit output | Enabled |
| Persistent script state | Empty table |

Cloning a Lua Combinator preserves its code, interval, and checkbox settings,
but starts it with a new empty script-state table.

## Script example

This forwards the red-wire iron-plate count:

```lua
local iron = get_signal("iron-plate", "red")
if iron > 0 then
    set_output("item", "iron-plate", iron)
end
```

This emits the virtual signal supplied by this mod:

```lua
set_output("virtual", "signal-lua-combinator", 1)
```

A Lua Combinator connected to that output can read it on its input:

```lua
local active = get_signal("signal-lua-combinator") > 0
```

`get_signal` reads input networks. An output queued with `set_output` is not
readable by `get_signal` in the same execution; connect it to another
combinator and wait for the circuit network to update. To read this
combinator's own output directly (as of the start of the current
execution), use `get_output_signal` instead.

## Script API

The complete reference, including argument validation and worked examples, is
in [`API_REFERENCE.md`](./API_REFERENCE.md). The runtime in
[`control.lua`](./control.lua) exposes the following values to combinator
scripts.

| Name | Behavior |
|---|---|
| `tick` | Current game tick. |
| `red`, `green` | Input tables indexed by signal name. |
| `get_signal(name [, color])` | Reads a signal from both input wires, or just `"red"` or `"green"`. |
| `get_output_signal(name [, color])` | Reads a signal from both output wires, or just `"red"` or `"green"`. |
| `get_network(color [, side])` | Returns a raw circuit network for `"red"`/`"green"` and optional `"input"`/`"output"` side. |
| `set_output(type, name, count)` | Queues an item, fluid, or virtual output signal. Counts are floored; zero does not queue a signal. |
| `clear_output()` | Removes all signals queued during the current execution. |
| `storage` | Persistent table scoped to this combinator. |
| `print(...)`, `dump(...)`, `log(...)`, `inspect(value)` | Chat and log helpers; the table-aware helpers format tables deterministically. |
| `clamp(value, min, max)`, `round(value [, decimals])` | Numeric helpers. |
| `script.on_event(...)`, `script.on_nth_tick(...)` | Per-combinator event handlers dispatched through the mod's shared Factorio event handlers. |
| `game`, `defines`, `remote`, `rendering`, `prototypes` | Factorio runtime objects exposed directly to scripts. |

The Lua standard-library values available in scripts are `math`, `table`,
`string`, `pairs`, `ipairs`, `next`, `select`, `type`, `tostring`,
`tonumber`, `pcall`, `xpcall`, `error`, `assert`, `rawget`, `rawset`,
`rawequal`, `rawlen`, `setmetatable`, `getmetatable`, and `unpack`.

`io`, `os`, `require`, `load`, `loadstring`, and `debug` are not exposed.
This is still a trusted-author environment: scripts can directly access the
Factorio runtime objects listed above.

### Scheduled and event-driven execution

With **Timer** enabled, code runs when the current tick is divisible by the
configured interval. With it disabled, automatic execution occurs only when
one of its registered `script.on_event` or `script.on_nth_tick` handlers
fires; **Run Now** remains available from the editor.

The runtime compiles each execution using a per-combinator environment and
catches compile and runtime errors. Errors are stored as the combinator's
last error and displayed by the editor rather than stopping the mod.

Event handlers are re-created from source on game load and configuration
changes because Lua closures are not saved by Factorio. During this setup
pass, script-facing circuit functions use inert values so registration does
not modify persistent state or output signals.

## Data-stage prototypes

[`data.lua`](./data.lua) defines the prototypes registered by the mod:

| Prototype | Name | Source definition |
|---|---|---|
| Entity | `lua-combinator` | Deep copy of the base `decider-combinator`, with teal/cyan-tinted sprites and `minable.result` changed to `lua-combinator`. |
| Item | `lua-combinator` | Places the entity; stack size 50; appears in the `circuit-network` subgroup. |
| Virtual signal | `signal-lua-combinator` | Uses the base decider-combinator icon and appears in the `virtual-signal` subgroup. |
| Recipe | `lua-combinator` | Initially disabled; costs 1 constant combinator, 3 advanced circuits, and 1 processing unit. |
| Technology | `lua-combinator` | Requires `circuit-network`, costs 150 automation, logistic, and chemical science packs at 30 seconds each, and unlocks the recipe. |

The virtual signal's localized name and description are in
[`locale/en/locale.cfg`](./locale/en/locale.cfg).

## Runtime implementation

[`control.lua`](./control.lua) maintains one record per placed entity in
`storage.combinators`, keyed by unit number. Each record stores the entity,
code, interval, persistent script storage, last error, output-enabled flag,
and timer-enabled flag.

When a script queues outputs, the runtime writes them to the copied
decider-combinator's control behavior as constant outputs behind an
always-true condition. Disabling output or clearing it through the editor
removes the behavior parameters.

The mod registers placement, removal, clone, lifecycle, GUI, and tick
handlers. Script-defined events are multiplexed so multiple placed Lua
Combinators can register handlers for the same Factorio event or tick
interval.

## Included scripts

The [`examples`](./examples) folder contains scripts intended to be pasted
into a Lua Combinator:

| Script | Purpose |
|---|---|
| [`example-plate-reminder.lua`](./examples/example-plate-reminder.lua) | Monitors an item count and emits status signals. |
| [`example_reactor_monitor.lua`](./examples/example_reactor_monitor.lua) | Monitors reactor/heat-exchanger temperature with hysteresis. |
| [`example_output_network_controller.lua`](./examples/example_output_network_controller.lua) | Aggregates rocket-silo status and controls entities on the output network. |
| [`example_rocket_monitor.lua`](./examples/example_rocket_monitor.lua) | Rocket-silo monitoring and output-network control example. |

## Project files

| Path | Purpose |
|---|---|
| [`data.lua`](./data.lua) | Data-stage entity, item, signal, recipe, and technology prototypes. |
| [`control.lua`](./control.lua) | Runtime execution engine, event dispatch, persistence, and GUI. |
| [`API_REFERENCE.md`](./API_REFERENCE.md) | Complete script-facing API documentation. |
| [`locale/en/locale.cfg`](./locale/en/locale.cfg) | English localization. |
| [`examples`](./examples) | Ready-to-paste example scripts. |
