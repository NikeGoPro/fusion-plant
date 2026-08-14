--[[
laser_node.lua -- IGNITION LASER ACTUATION NODE
Computer wired to the Laser Amplifier bank's redstone trigger.

Current wiring: direct redstone from CONFIG.SIDE (back of computer).
Future wiring: bundled cable - set CONFIG.COLOR and the mapping below.

---------------------------------------------------------------
-- BUNDLED CABLE COLOR MAP (when CONFIG.COLOR is used)
--   white  : LASER FIRE - amplifier bank discharge trigger
--   (reserved for future actuators on the same bundle:
--    orange : MS-1V1, magenta : MS-2V1, lightBlue : spare, ...)
---------------------------------------------------------------

Behavior:
  - Listens to the master's "scada_state" broadcasts and DETECTS the
    ignition sequence: when the sequence enters its FIRE stage, the
    output energizes for CONFIG.PULSE seconds (one shot per sequence),
    dumping the amplifiers into the Focus Matrix.
  - Manual test: press T on this terminal, or send
    { type="actuate", target="LASER", set="fire" } on "scada_actuate".
  - FAIL-SAFE: output de-energizes on pulse end, on link loss, and at
    program start/stop. The line is never left hot.

Amplifier setup: point every Laser Amplifier at the Focus Matrix and
set its GUI redstone mode so it EMITS ONLY WHILE POWERED (activation
on high signal). Charge the amplifiers continuously from your lasers;
this node only pulls the trigger.

Install: wget run <repo>/install.lua laser
]]

local CONFIG = {
    SIDE  = "back",
    COLOR = nil,   -- e.g. "white" to drive a bundled cable channel
    PULSE = 3.0,   -- seconds the fire line stays energized
}

---------------------------------------------------------------
local function setOut(on)
    if CONFIG.COLOR then
        redstone.setBundledOutput(CONFIG.SIDE,
            on and colors[CONFIG.COLOR] or 0)
    else
        redstone.setOutput(CONFIG.SIDE, on)
    end
end
setOut(false) -- never boot hot

local opened = 0
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
        if not rednet.isOpen(name) then rednet.open(name) end
        opened = opened + 1
    end
end
if opened == 0 then
    error("Laser node needs a modem (wired or ender)", 0)
end

---------------------------------------------------------------
local lastSeen = -100
local firing = false
local fireUntil = 0
local firedThisSeq = false

local function fire(reason)
    if firing then return end
    firing = true
    fireUntil = os.clock() + CONFIG.PULSE
    setOut(true)
    print(("[%s] *** FIRE *** (%s) - line energized %.1fs"):format(
        os.date("%H:%M:%S"), reason, CONFIG.PULSE))
end

print("Laser actuation node online (" .. opened .. " modem(s)).")
print("Watching for ignition FIRE stage. Press T to test-fire.")
rednet.broadcast({ type = "hello", role = "NODE_LASER" }, "scada_hello")

local tick = 0
local timer = os.startTimer(0.25)

while true do
    local event, a, b, c = os.pullEvent()
    if event == "timer" and a == timer then
        tick = tick + 1
        if tick % 20 == 1 then
            rednet.broadcast({ type = "hello", role = "NODE_LASER" },
                "scada_hello")
        end
        -- pulse expiry
        if firing and os.clock() >= fireUntil then
            firing = false
            setOut(false)
            print(("[%s] fire line de-energized"):format(os.date("%H:%M:%S")))
        end
        -- FAIL-SAFE: master silent -> line down
        if firing and os.clock() - lastSeen > 5 then
            firing = false
            setOut(false)
            print("link loss - fail-safe de-energize")
        end
        timer = os.startTimer(0.25)
    elseif event == "rednet_message" and c == "scada_state" then
        if type(b) == "table" and b.type == "state" then
            lastSeen = os.clock()
            local stage = b.seq and b.seq.stage
            if b.igniting and stage == "fire" then
                if not firedThisSeq then
                    firedThisSeq = true
                    fire("ignition sequence FIRE stage")
                end
            elseif not b.igniting then
                firedThisSeq = false -- re-arm for the next sequence
            end
        end
    elseif event == "rednet_message" and c == "scada_actuate" then
        if type(b) == "table" and b.target == "LASER"
            and b.set == "fire" then
            fire("remote command")
        end
    elseif event == "char" and (a == "t" or a == "T") then
        fire("local test")
    end
end
