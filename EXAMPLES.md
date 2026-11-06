# Built-in examples

Every script below ships with the mod. Open a Lua Combinator, pick one from
the **Examples** drop-down and press **Load**, then **Apply**. They are also
plain files in [`examples/`](./examples) if you want to read or copy them.

Scripts with *Timer: off* are event-driven: they run only when the events they
register fire (see [API_REFERENCE.md](./API_REFERENCE.md#7-events)).


## Basics

| Example | What it does | Interval |
|---|---|---|
| [Pass-through](./examples/basics/passthrough.lua) | Forward everything on the red wire to the output, plus one hand-picked signal. | 1 tick |
| [Persistent counter](./examples/basics/counter.lua) | Counts executions in storage (survives saves) and resets on signal-R. | 60 ticks |
| [Filter & scale](./examples/basics/filter_scale.lua) | Keep only items above a threshold, multiply them, and drop everything else. | 10 ticks |
| [Clock & waveforms](./examples/basics/clock.lua) | Generates a sawtooth (signal-S), square wave (signal-Q), sine (signal-W) and a 1-tick pulse (signal-P). | 1 tick |
| [Edge detector](./examples/basics/edge_pulse.lua) | Turns a level into one-shot pulses and counts how often an input switched on. | 1 tick |
| [Memory cell](./examples/basics/sample_hold.lua) | Sample-and-hold: stores all inputs while signal-S > 0, clears on signal-R. | 1 tick |
| [Multiplexer](./examples/basics/multiplexer.lua) | Outputs only the N-th red-wire signal, where N comes from signal-I on green. | 1 tick |
| [Top-N selector](./examples/basics/top_n.lua) | Finds the N most plentiful items on the input and outputs only those. | 30 ticks |
| [Digit splitter](./examples/basics/digit_splitter.lua) | Splits signal-N into decimal digits (signal-0 = ones, signal-1 = tens, …) for lamp displays. | 5 ticks |
| [Signal statistics](./examples/basics/statistics.lua) | Sum, count, min, max and average of every item on the input wires. | 30 ticks |

## Logistics

| Example | What it does | Interval |
|---|---|---|
| [Stock monitor](./examples/logistics/stock_monitor.lua) | Watches one item in a chest: yellow/red status signals, chat warnings and a map alert when it runs low. | 60 ticks |
| [Restock planner](./examples/logistics/restock_planner.lua) | Compares chest contents against a target list and outputs what is missing. | 60 ticks |
| [Mall recipe selector](./examples/logistics/recipe_selector.lua) | Picks the item furthest below its target and outputs it alone, for an assembler set to 'Set recipe'. | 120 ticks |
| [Train stop limit](./examples/logistics/train_limit.lua) | Sets a train stop's limit (signal-L) from how many full train loads fit in the buffer chests. | 60 ticks |
| [Throughput meter](./examples/logistics/throughput_meter.lua) | Measures how fast the total item count on the red wire changes (items/minute), smoothed over 10 samples. | 60 ticks |
| [Rocket silo monitor](./examples/logistics/rocket_monitor.lua) | Finds every rocket silo wired to the red input and reports how many are ready. | 60 ticks |
| [Requester chest controller](./examples/logistics/requester_controller.lua) | Drives the logistic requests of requester chests on the output network directly from Lua. | 120 ticks |

## Power & fluids

| Example | What it does | Interval |
|---|---|---|
| [Reactor temperature](./examples/power/reactor_monitor.lua) | Hysteresis on a reactor/heat-exchanger temperature: signal-green switches on above 500 °C and off below 400 °C. | 20 ticks |
| [Backup power switch](./examples/power/backup_power.lua) | Turns backup steam power on when accumulators drop below 20 % and off again above 80 %. | 30 ticks |
| [PID tank level (PWM pump)](./examples/power/pid_tank.lua) | A PID controller keeps a storage tank at a set level by pulse-width-modulating a pump. | 5 ticks |

## World & game API

| Example | What it does | Interval |
|---|---|---|
| [Day / night sensor](./examples/world/day_night.lua) | Reads the surface's darkness and time of day; switches lamps on at dusk. | 60 ticks |
| [Pollution monitor](./examples/world/pollution_monitor.lua) | Measures pollution at the combinator's chunk and tracks its trend. | 300 ticks |
| [Enemy radar](./examples/world/enemy_radar.lua) | Counts enemy units, spawners and worms near the combinator and raises an alert. | 120 ticks |
| [Player proximity](./examples/world/player_proximity.lua) | Detects players within a radius – open gates, switch on lights, greet visitors. | 15 ticks |
| [Research status](./examples/world/research_status.lua) | Outputs current research progress and queue length, with a floating label. | 60 ticks |
| [Production statistics](./examples/world/production_stats.lua) | Outputs the force's per-minute production and consumption of chosen items, straight from the game's statistics. | 300 ticks |
| [Live map tag](./examples/world/map_tag.lua) | Keeps a map (chart) tag next to the combinator updated with live numbers from the red wire. | 300 ticks |
| [Hologram display](./examples/world/hologram.lua) | Draws the five biggest inputs as floating rich text above the combinator. | 30 ticks |
| [Game of Life display](./examples/world/life_display.lua) | Runs Conway's Game of Life on a 16x16 grid drawn with the rendering API above the combinator. | 10 ticks |

## Events

| Example | What it does | Interval |
|---|---|---|
| [Welcome message](./examples/events/welcome.lua) | Event-driven: greets players as they join and counts online players. Timer off. | Timer: off |
| [Rocket launch counter](./examples/events/rocket_counter.lua) | Counts rocket launches with on_rocket_launched and pulses signal-L on every launch. | Timer: off |
| [Casualty alarm](./examples/events/casualty_alarm.lua) | Listens to on_entity_died and raises an alarm when your buildings are destroyed nearby. | 60 ticks |
| [Chat-controlled switch](./examples/events/chat_switch.lua) | Type '!lights on' / '!lights off' / '!set N' in chat to drive circuit signals. | Timer: off |
| [Research announcer](./examples/events/research_announcer.lua) | Announces finished research in chat and counts technologies researched. | Timer: off |

## Wireless & shared state

| Example | What it does | Interval |
|---|---|---|
| [Wireless transmitter](./examples/network/wireless_transmitter.lua) | Broadcasts every input signal on a named channel – no wires across the map needed. | 30 ticks |
| [Wireless receiver](./examples/network/wireless_receiver.lua) | Outputs everything transmitted on a named channel. | 30 ticks |
| [Shared memory](./examples/network/shared_memory.lua) | Uses the `shared` table to keep a factory-wide tally that every Lua Combinator can read and update. | 60 ticks |

## Advanced

| Example | What it does | Interval |
|---|---|---|
| [Station state machine](./examples/advanced/state_machine.lua) | A loading-station sequencer: IDLE -> LOADING -> DEPARTING, with timeouts, written as a table of states. | 10 ticks |
| [Round-robin sequencer](./examples/advanced/sequencer.lua) | Steps through a list of signals, emitting one per execution – drive a filter inserter or a train schedule. | 120 ticks |
| [Morse code beacon](./examples/advanced/morse.lua) | Blinks a text message in Morse code on signal-M (hook up a lamp or speaker). | 6 ticks |
| [Construction logger](./examples/advanced/event_bus.lua) | Combines several events (built / mined / died) into live counters and a running log. | Timer: off |

## Adding your own

Create a file in the matching `examples/<category>/` folder that returns
`{ title = ..., description = ..., interval = ..., timer = true|false, code = [==[ ... ]==] }`
and add its path to [`examples/index.lua`](./examples/index.lua). The test suite
(`python3 tests/run.py`) compiles and runs every listed example against a mock game.
