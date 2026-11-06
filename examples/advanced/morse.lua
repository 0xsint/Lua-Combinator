return {
    title       = "Morse code beacon",
    description = "Blinks a text message in Morse code on signal-M (hook up a lamp or speaker).",
    interval    = 6,
    code = [==[
-- Morse code beacon -------------------------------------------------------------
-- One execution = one Morse time unit (6 ticks = 0.1 s).
local MESSAGE = "SOS FACTORIO"

local CODE = {
    A=".-", B="-...", C="-.-.", D="-..", E=".", F="..-.", G="--.", H="....",
    I="..", J=".---", K="-.-", L=".-..", M="--", N="-.", O="---", P=".--.",
    Q="--.-", R=".-.", S="...", T="-", U="..-", V="...-", W=".--", X="-..-",
    Y="-.--", Z="--..", ["1"]=".----", ["2"]="..---", ["3"]="...--",
    ["4"]="....-", ["5"]=".....", ["6"]="-....", ["7"]="--...", ["8"]="---..",
    ["9"]="----.", ["0"]="-----",
}

-- Build the on/off timeline once and cache it in storage.
if storage.message ~= MESSAGE then
    local t = {}
    local function push(v, n) for _ = 1, n do t[#t + 1] = v end end
    for ch in MESSAGE:upper():gmatch(".") do
        if ch == " " then
            push(0, 4)                      -- word gap (7 total with letter gap)
        elseif CODE[ch] then
            for sym in CODE[ch]:gmatch(".") do
                push(1, sym == "." and 1 or 3)
                push(0, 1)                  -- gap between symbols
            end
            push(0, 2)                      -- letter gap (3 total)
        end
    end
    push(0, 7)                              -- pause before repeating
    storage.timeline, storage.message, storage.pos = t, MESSAGE, 0
end

storage.pos = storage.pos % #storage.timeline + 1
set_output("virtual", "signal-M", storage.timeline[storage.pos])
]==],
}
