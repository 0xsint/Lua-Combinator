return {
    title       = "Game of Life display",
    description = "Runs Conway's Game of Life on a 16x16 grid drawn with the rendering API above the combinator.",
    interval    = 10,
    code = [==[
-- Game of Life display ----------------------------------------------------------
-- signal-R (any wire) re-seeds the board.  Shows what rendering + storage can do.
local W, H, CELL = 16, 16, 0.25
local ALIVE = {r = 0.2, g = 1.0, b = 0.6, a = 0.9}
local DEAD  = {r = 0.05, g = 0.1, b = 0.1, a = 0.4}
if not entity then return end

local function idx(x, y) return ((y - 1) % H) * W + ((x - 1) % W) + 1 end

local function seed()
    local g = {}
    for i = 1, W * H do g[i] = 0 end
    -- a glider and an R-pentomino
    for _, p in ipairs{{2,1},{3,2},{1,3},{2,3},{3,3},{9,8},{10,8},{8,9},{9,9},{9,10}} do
        g[idx(p[1], p[2])] = 1
    end
    return g
end

if not storage.grid or get_signal("signal-R") > 0 then storage.grid = seed() end

-- (re)create one rectangle per cell
local cells = storage.cells
if not (cells and cells[1] and cells[1].valid) then
    cells = {}
    for y = 1, H do
        for x = 1, W do
            local ox = (x - W / 2 - 1) * CELL
            local oy = (y - H - 4) * CELL
            cells[idx(x, y)] = rendering.draw_rectangle{
                color = DEAD, filled = true, surface = entity.surface,
                left_top     = {entity = entity, offset = {ox, oy}},
                right_bottom = {entity = entity, offset = {ox + CELL * 0.9, oy + CELL * 0.9}},
            }
        end
    end
    storage.cells = cells
    storage.shown = {}          -- what each rectangle currently displays
end
local shown = storage.shown

-- step the simulation
local g, nxt, alive = storage.grid, {}, 0
for y = 1, H do
    for x = 1, W do
        local n = 0
        for dy = -1, 1 do
            for dx = -1, 1 do
                if dx ~= 0 or dy ~= 0 then n = n + g[idx(x + dx, y + dy)] end
            end
        end
        local i = idx(x, y)
        local v = (n == 3 or (n == 2 and g[i] == 1)) and 1 or 0
        nxt[i] = v
        alive = alive + v
        if v ~= (shown[i] or 0) then
            cells[i].color = v == 1 and ALIVE or DEAD
            shown[i] = v
        end
    end
end
storage.grid = nxt
storage.generation = (storage.generation or 0) + 1

set_output("virtual", "signal-A", alive)
set_output("virtual", "signal-G", storage.generation)
]==],
}
