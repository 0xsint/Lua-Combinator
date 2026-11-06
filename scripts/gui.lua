-- ===========================================================================
-- scripts/gui.lua  –  Code editor window
-- ===========================================================================
--
-- Elements that trigger actions carry tags = { lc = "<action>" }; the click
-- handler dispatches on that tag through the ACTIONS table, so adding a
-- button means adding one entry there.
-- ===========================================================================

local util      = require("scripts.util")
local signals   = require("scripts.signals")
local outputs   = require("scripts.outputs")
local scheduler = require("scripts.scheduler")
local registry  = require("scripts.registry")
local sandbox   = require("scripts.sandbox")
local examples  = require("examples.index")

local gui = {}

local GUI_NAME   = "lua-combinator-gui"
local WIDTH      = 640
local MAX_LABELS = 100

local COLORS = {
    error = {r = 1.0, g = 0.35, b = 0.35},
    ok    = {r = 0.45, g = 1.0, b = 0.45},
    dim   = {r = 0.65, g = 0.65, b = 0.65},
    hint  = {r = 0.55, g = 0.85, b = 1.0},
    red   = {r = 1.0, g = 0.35, b = 0.35},
    green = {r = 0.3, g = 1.0, b = 0.4},
    out   = {r = 0.4, g = 0.9, b = 1.0},
}

local TEMPLATE = [[-- Lua Combinator
-- Pick an example from the list above and press "Load", or start here.
-- Reference: Help tab below, or API_REFERENCE.md in the mod folder.

local iron = get_signal("iron-plate")   -- red + green input
if iron > 0 then
    out("iron-plate", iron)             -- output (type worked out for you)
end
]]

local HELP = [==[[font=default-bold]Inputs[/font]
  red / green – {name = count}       get_signal(name [, "red"|"green"])
  signals([color [, side]]) – sorted list of {type, name, quality, count}
  get_output_signal(name [, color])   get_network(color [, side])
[font=default-bold]Outputs[/font]  (timer runs rebuild the output; event handlers edit it)
  out(name, count)   set_output(type, name, count [, quality])   add_output(...)
  set_outputs{name = count}   forward([color] [, filter])   clear_output()   get_outputs()
[font=default-bold]State[/font]
  storage – this combinator     shared – all combinators     unit_number, tick, entity
  transmit(channel, {name = count})   receive(channel)  – wireless channels
[font=default-bold]Helpers[/font]  (first argument is a key you choose)
  rising_edge  falling_edge  changed  hysteresis  latch  every  delay
  average  ema  rate  pid
  clamp  round  format_number  rich_text  signal_type  inspect
[font=default-bold]Output to players[/font]
  print  dump  log  alert(msg [, icon])  label(text [, {color, scale}])
[font=default-bold]Events[/font]  (registered on Apply and on load)
  script.on_event(id_or_ids, fn)   script.on_nth_tick(n, fn)   script.on_init(fn)
[font=default-bold]Game API[/font]
  game  defines  prototypes  rendering  remote  helpers  settings]==]

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function get_frame(player)
    local f = player.gui.screen[GUI_NAME]
    if f and f.valid then return f end
end

local function find(frame, name) return util.find_child(frame, name) end

local function example_items()
    local items = {}
    for i, ex in ipairs(examples) do items[i] = ex.category .. "  ›  " .. ex.title end
    return items
end

local function fill_signal_pane(pane, list, color)
    pane.clear()
    if #list == 0 then
        pane.add{type = "label", caption = "(none)"}.style.font_color = COLORS.dim
        return
    end
    for i, s in ipairs(list) do
        if i > MAX_LABELS then
            pane.add{type = "label", caption = "… " .. (#list - MAX_LABELS) .. " more"}
            break
        end
        local key = signals.key(s.name, s.quality)
        local l = pane.add{
            type    = "label",
            caption = signals.rich_text(s.type, s.name, s.quality) .. " " .. key .. " = " .. s.count,
        }
        l.style.font_color = color
    end
end

local function output_list(record)
    local list = {}
    for _, e in ipairs(outputs.sorted(record.outputs or {})) do
        list[#list + 1] = {type = e.signal.type, name = e.signal.name, quality = e.signal.quality, count = e.count}
    end
    return list
end

local function status_caption(record)
    local s = record.stats or {}
    local parts = {
        "Runs " .. (s.runs or 0),
        "Events " .. (s.events or 0),
        "Errors " .. (s.errors or 0),
    }
    if s.last_run then parts[#parts + 1] = "Last run: tick " .. s.last_run end
    if record.next_run then
        parts[#parts + 1] = "Next: tick " .. record.next_run
    elseif record.run_on_timer == false then
        parts[#parts + 1] = "Timer off"
    end
    return table.concat(parts, "  ·  ")
end

local function set_message(frame, text, color)
    local lbl = find(frame, "lc_error")
    if lbl then
        lbl.caption = text or ""
        lbl.style.font_color = color or COLORS.error
    end
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

function gui.open(player, entity)
    gui.close(player)
    local record = registry.create(entity)
    if not record then return end
    storage.open_guis[player.index] = record.unit_number

    local frame = player.gui.screen.add{type = "frame", name = GUI_NAME, direction = "vertical"}
    frame.auto_center = true
    frame.style.width = WIDTH + 24

    -- ---- Title bar ----
    local bar = frame.add{type = "flow", direction = "horizontal"}
    bar.drag_target = frame
    bar.add{
        type = "label", style = "frame_title", ignored_by_interaction = true,
        caption = {"lua-combinator.gui-title", record.unit_number},
    }
    local drag = bar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
    drag.style.horizontally_stretchable = true
    drag.style.height = 24
    bar.add{
        type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
        tags = {lc = "close"}, tooltip = {"gui.close-instruction"},
    }

    -- ---- Example browser ----
    local ex_row = frame.add{type = "flow", direction = "horizontal"}
    ex_row.style.vertical_align = "center"
    ex_row.add{type = "label", caption = "Examples"}
    local dd = ex_row.add{type = "drop-down", name = "lc_examples", items = example_items(), selected_index = 1,
                          tags = {lc = "example_select"}}
    dd.style.horizontally_stretchable = true
    ex_row.add{type = "button", caption = "Load", tags = {lc = "example_load"},
               tooltip = "Replace the editor contents with this example (not applied until you press Apply)"}

    local desc = frame.add{type = "label", name = "lc_example_desc", caption = examples[1] and examples[1].description or ""}
    desc.style.single_line   = false
    desc.style.maximal_width = WIDTH
    desc.style.font_color    = COLORS.hint

    -- ---- Code editor ----
    local code_box = frame.add{type = "text-box", name = "lc_code", text = record.code ~= "" and record.code or TEMPLATE}
    code_box.style.width  = WIDTH
    code_box.style.height = 360
    code_box.word_wrap = false

    -- ---- Settings row ----
    local settings_row = frame.add{type = "flow", direction = "horizontal"}
    settings_row.style.vertical_align = "center"
    settings_row.style.horizontal_spacing = 6
    settings_row.add{
        type = "checkbox", name = "lc_timer", caption = "Timer", state = record.run_on_timer ~= false,
        tags = {lc = "toggle_timer"},
        tooltip = "Run the code every N ticks.\nWhen off, the code only runs through script.on_event / on_nth_tick handlers (and Run Now).",
    }
    settings_row.add{type = "label", caption = "every"}
    local interval = settings_row.add{
        type = "textfield", name = "lc_interval", text = tostring(record.interval),
        numeric = true, allow_negative = false, allow_decimal = false, lose_focus_on_confirm = true,
    }
    interval.style.width = 64
    settings_row.add{type = "label", caption = "ticks"}
    settings_row.add{
        type = "checkbox", name = "lc_output", caption = "Output enabled", state = record.output_enabled ~= false,
        tags = {lc = "toggle_output"},
        tooltip = "When unchecked the combinator puts nothing on its output wires.",
    }
    local spacer = settings_row.add{type = "empty-widget"}
    spacer.style.horizontally_stretchable = true
    settings_row.add{type = "button", caption = "▶ Run Now", style = "green_button", tags = {lc = "run"},
                     tooltip = "Save and execute immediately"}

    -- ---- Status / errors ----
    local status = frame.add{type = "label", name = "lc_status", caption = status_caption(record)}
    status.style.font_color = COLORS.dim
    local err = frame.add{type = "label", name = "lc_error", caption = record.last_error and ("⚠ " .. record.last_error) or ""}
    err.style.font_color    = COLORS.error
    err.style.single_line   = false
    err.style.maximal_width = WIDTH

    -- ---- Tabs ----
    local tabs = frame.add{type = "tabbed-pane", name = "lc_tabs"}
    tabs.style.width = WIDTH

    local sig_tab = tabs.add{type = "tab", caption = "Signals"}
    local sig_flow = tabs.add{type = "flow", direction = "horizontal"}
    for _, col in ipairs{{"lc_sig_red", "● Red input", COLORS.red},
                         {"lc_sig_green", "● Green input", COLORS.green},
                         {"lc_sig_out", "● Output", COLORS.out}} do
        local v = sig_flow.add{type = "flow", direction = "vertical"}
        v.add{type = "label", caption = col[2]}.style.font_color = col[3]
        local pane = v.add{type = "scroll-pane", name = col[1]}
        pane.style.width  = math.floor(WIDTH / 3) - 10
        pane.style.height = 140
    end
    tabs.add_tab(sig_tab, sig_flow)

    local st_tab = tabs.add{type = "tab", caption = "Storage"}
    local st_box = tabs.add{type = "text-box", name = "lc_storage"}
    st_box.read_only = true
    st_box.style.width  = WIDTH - 20
    st_box.style.height = 160
    tabs.add_tab(st_tab, st_box)

    local help_tab = tabs.add{type = "tab", caption = "Help"}
    local help_pane = tabs.add{type = "scroll-pane"}
    help_pane.style.height = 160
    local help = help_pane.add{type = "label", caption = HELP}
    help.style.single_line   = false
    help.style.maximal_width = WIDTH - 30
    tabs.add_tab(help_tab, help_pane)
    tabs.selected_tab_index = 1

    -- ---- Buttons ----
    local buttons = frame.add{type = "flow", direction = "horizontal"}
    buttons.style.top_padding = 4
    buttons.add{type = "button", caption = "✔ Apply", style = "confirm_button", tags = {lc = "apply"},
                tooltip = "Save code and settings, register event handlers and run once"}
    buttons.add{type = "button", caption = "Check syntax", tags = {lc = "check"}}
    buttons.add{type = "button", caption = "✖ Clear Output", tags = {lc = "clear"}}
    buttons.add{type = "button", caption = "Reset storage", tags = {lc = "reset_storage"},
                tooltip = "Empty this combinator's storage table and helper state"}

    gui.refresh(player)
    player.opened = frame
end

function gui.close(player)
    local frame = get_frame(player)
    if frame then frame.destroy() end
    storage.open_guis[player.index] = nil
end

-- ---------------------------------------------------------------------------
-- Refresh (called every 20 ticks for open windows)
-- ---------------------------------------------------------------------------

function gui.refresh(player)
    local frame = get_frame(player)
    if not frame then
        storage.open_guis[player.index] = nil
        return
    end
    local record = registry.get(storage.open_guis[player.index])
    if not (record and record.entity and record.entity.valid) then
        gui.close(player)
        return
    end
    local entity = record.entity

    local status = find(frame, "lc_status")
    if status then status.caption = status_caption(record) end
    if record.last_error then set_message(frame, "⚠ " .. record.last_error) end

    local tabs = find(frame, "lc_tabs")
    local tab = tabs and tabs.selected_tab_index or 1
    if tab == 1 then
        local _, red   = signals.read_network(entity.get_circuit_network(signals.WIRES.input.red))
        local _, green = signals.read_network(entity.get_circuit_network(signals.WIRES.input.green))
        fill_signal_pane(find(frame, "lc_sig_red"), red, COLORS.red)
        fill_signal_pane(find(frame, "lc_sig_green"), green, COLORS.green)
        fill_signal_pane(find(frame, "lc_sig_out"), output_list(record), COLORS.out)
    elseif tab == 2 then
        local box = find(frame, "lc_storage")
        if box then box.text = util.inspect(record.storage) end
    end
end

function gui.refresh_all()
    for player_index in pairs(storage.open_guis) do
        local player = game.get_player(player_index)
        if player and player.valid then
            gui.refresh(player)
        else
            storage.open_guis[player_index] = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

local function read_form(frame)
    local cfg = {}
    local code = find(frame, "lc_code")
    if code then cfg.code = code.text end
    local interval = find(frame, "lc_interval")
    if interval then cfg.interval = math.max(1, tonumber(interval.text) or 1) end
    local timer = find(frame, "lc_timer")
    if timer then cfg.run_on_timer = timer.state end
    local out = find(frame, "lc_output")
    if out then cfg.output_enabled = out.state end
    return cfg
end

local function report(player, frame, record)
    if record.last_error then
        set_message(frame, "⚠ " .. record.last_error)
    else
        set_message(frame, "✔ OK", COLORS.ok)
    end
    gui.refresh(player)
end

local ACTIONS = {}

function ACTIONS.close(player) gui.close(player) end

function ACTIONS.apply(player, frame, record)
    registry.configure(record, read_form(frame), true)
    report(player, frame, record)
    player.print({"lua-combinator.applied"}, {color = COLORS.ok})
end

function ACTIONS.run(player, frame, record)
    local cfg = read_form(frame)
    if cfg.code ~= record.code then
        registry.configure(record, cfg, true)
    else
        sandbox.run(record, game.tick)
    end
    report(player, frame, record)
end

function ACTIONS.check(player, frame)
    local code = find(frame, "lc_code")
    local err = code and sandbox.check(code.text)
    if err then set_message(frame, "⚠ " .. err) else set_message(frame, "✔ Syntax OK", COLORS.ok) end
end

function ACTIONS.clear(player, frame, record)
    outputs.clear(record)
    player.print({"lua-combinator.cleared"}, {color = COLORS.dim})
    gui.refresh(player)
end

function ACTIONS.reset_storage(player, frame, record)
    record.storage = {}
    record.helper_state = {}
    set_message(frame, "Storage cleared.", COLORS.ok)
    gui.refresh(player)
end

function ACTIONS.example_load(player, frame)
    local dd = find(frame, "lc_examples")
    local ex = dd and examples[dd.selected_index]
    if not ex then return end
    find(frame, "lc_code").text = ex.code
    find(frame, "lc_interval").text = tostring(ex.interval)
    find(frame, "lc_timer").state = ex.timer
    set_message(frame, "Loaded \"" .. ex.title .. "\" – press Apply to use it.", COLORS.hint)
end

function ACTIONS.toggle_timer(player, frame, record, element)
    record.run_on_timer = element.state
    scheduler.reschedule(record, game.tick)
    gui.refresh(player)
end

function ACTIONS.toggle_output(player, frame, record, element)
    record.output_enabled = element.state
    outputs.apply(record, record.outputs or {})
    gui.refresh(player)
end

local function dispatch(event)
    local element = event.element
    if not (element and element.valid) then return end
    local action = element.tags and element.tags.lc
    local fn = action and ACTIONS[action]
    if not fn then return end
    local player = game.get_player(event.player_index)
    local frame = get_frame(player)
    if not frame then return end
    local record = registry.get(storage.open_guis[player.index])
    if not record and action ~= "close" then
        gui.close(player)
        return
    end
    fn(player, frame, record, element)
end

-- ---------------------------------------------------------------------------
-- Event handlers (wired up in control.lua)
-- ---------------------------------------------------------------------------

gui.on_click = dispatch
gui.on_checked_state_changed = dispatch

function gui.on_selection_state_changed(event)
    local element = event.element
    if not (element and element.valid and element.name == "lc_examples") then return end
    local player = game.get_player(event.player_index)
    local frame = get_frame(player)
    local ex = examples[element.selected_index]
    local desc = frame and find(frame, "lc_example_desc")
    if desc and ex then desc.caption = ex.description end
end

function gui.on_opened(event)
    local entity = event.entity
    if not (entity and entity.valid and entity.name == util.ENTITY_NAME) then return end
    local player = game.get_player(event.player_index)
    player.opened = nil   -- suppress the vanilla decider GUI
    gui.open(player, entity)
end

function gui.on_closed(event)
    local element = event.element
    if element and element.valid and element.name == GUI_NAME then
        gui.close(game.get_player(event.player_index))
    end
end

function gui.on_tab_changed(event)
    local element = event.element
    if element and element.valid and element.name == "lc_tabs" then
        gui.refresh(game.get_player(event.player_index))
    end
end

function gui.on_tick(tick)
    if tick % 20 == 0 and next(storage.open_guis) then gui.refresh_all() end
end

return gui
