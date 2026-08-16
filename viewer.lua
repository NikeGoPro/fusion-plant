--[[
viewer.lua -- RIGHT FRONT WALL: steam plant display (fixed purpose)
Requires ui.lua. Monitor wall + modem on the plant network.
No configuration - this is always the steam wall.

Shows the six-turbine table with SG level green bands, induction
matrix / switchyard, and the event log. Display only; follows state
snapshots broadcast by the master (hmi.lua).
]]

local ui = require("ui")

local scr = ui.attach(nil, 0.5)
local modem = peripheral.find("modem")
if not modem then error("Steam wall needs a modem on the plant network", 0) end
rednet.open(peripheral.getName(modem))

local S = nil
local MYROLE = "VIEW_STEAM"
local lastSeen = -100
local flash = false
local W, H = scr.w, scr.h

---------------------------------------------------------------
-- CHROME
---------------------------------------------------------------
local function chrome(title)
    scr:fill(1, 1, W, 2, ui.c.panel)
    scr:text(3, 1, "FUSION FACILITY - UNIT 1", ui.c.accent, ui.c.panel)
    scr:center(1, W, 1, title, ui.c.text, ui.c.panel)
    scr:text(W - 10, 1, os.date("%H:%M:%S"), ui.c.dim, ui.c.panel)
    if not S or os.clock() - lastSeen > 2 then
        scr:center(1, W, math.floor(H / 2), "LINK LOSS - WAITING FOR MASTER",
            ui.c.alarm, ui.c.bg)
        return false
    end
    local status, sc = "STANDBY", ui.c.dim
    if S.igniting then status, sc = "IGNITION SEQUENCE IN PROGRESS", ui.c.warn
    elseif S.data.ignited then status, sc = d.modeText or "MODE 1", ui.c.ok end
    scr:center(1, W, 2, status, sc, ui.c.panel)
    if (S.unacked or 0) > 0 and flash then
        scr:text(W - 22, 1, " ALM " .. S.unacked .. " ", ui.c.text, ui.c.alarm)
    end
    return true
end

local function eventLog(x1, y1, x2, y2)
    scr:panel(x1, y1, x2, y2, "EVENT LOG")
    if not S.log then return end
    local maxRows = y2 - y1 - 2
    for i = 1, math.min(#S.log, maxRows) do
        local e = S.log[i]
        scr:text(x1 + 2, y1 + 1 + i, e.time .. "  " .. e.text,
            e.colour or ui.c.dim, ui.c.panel)
    end
end

---------------------------------------------------------------
-- STEAM WALL
---------------------------------------------------------------
local function render()
    scr:beginFrame()
    if S and os.clock() - lastSeen < 2 and S.igniting then
        local on = (tick % 6) < 3
        scr:center(1, W, math.floor(H / 2), "IGNITION SEQUENCE IN PROGRESS",
            on and ui.c.warn or ui.c.line)
        scr:center(1, W, math.floor(H / 2) + 2, "EYES ON CENTER DISPLAY", ui.c.dim)
        scr:flush()
        return
    end
    if not chrome("TURBINE HALL / STEAM PLANT") then scr:flush() return end
    local d = S.data
    scr:panel(2, 4, W - 1, H - 20, "TURBINES")
    local cols = { 4, 14, 30, 48, 62, 74, 88 }
    local heads = { "UNIT", "STATUS", "FLOW mB/t", "PROD FE/t", "STM %", "BUF %", "SG LVL" }
    for i, hd in ipairs(heads) do
        scr:text(cols[i], 6, hd, ui.c.accent, ui.c.panel)
    end
    scr:fill(4, 7, W - 4, 7, ui.c.line)
    local totalFlow, totalProd = 0, 0
    for i, t in ipairs(d.turbines) do
        local y = 7 + i * 2
        local status, sc = "ONLINE", ui.c.ok
        if not t.online then status, sc = "ISOLATED", ui.c.alarm
        elseif d.ignited and t.flow < 100 then status, sc = "TRIPPED", ui.c.warn
        elseif not d.ignited then status, sc = "STANDBY", ui.c.dim end
        scr:text(cols[1], y, "TB-" .. i, ui.c.text, ui.c.panel)
        scr:text(cols[2], y, status, sc, ui.c.panel)
        scr:text(cols[3], y, ui.si(t.flow, ""), ui.c.steam, ui.c.panel)
        scr:text(cols[4], y, ui.si(t.prod, ""), ui.c.caution, ui.c.panel)
        scr:text(cols[5], y, ui.pct(t.steamPct), ui.c.text, ui.c.panel)
        scr:text(cols[6], y, ui.pct(t.buffer), ui.c.text, ui.c.panel)
        if t.water == nil then
            scr:text(cols[7], y, "NO INSTR", ui.c.dim, ui.c.panel)
        else
            scr:bandBar(cols[7], y, 20, t.water, 0.40, 0.70)
            scr:text(cols[7] + 22, y, ui.pct(t.water), ui.c.text, ui.c.panel)
        end
        totalFlow = totalFlow + t.flow
        totalProd = totalProd + t.prod
    end
    local ty = 9 + #d.turbines * 2
    scr:fill(4, ty - 1, W - 4, ty - 1, ui.c.line)
    scr:text(cols[1], ty, "TOTAL", ui.c.accent, ui.c.panel)
    scr:text(cols[3], ty, ui.si(totalFlow, ""), ui.c.steam, ui.c.panel)
    scr:text(cols[4], ty, ui.si(totalProd, ""), ui.c.caution, ui.c.panel)

    scr:panel(2, H - 18, W - 1, H - 13, "INDUCTION MATRIX / SWITCHYARD")
    local gw = math.floor((W - 12) / 3)
    scr:gaugeH(4, H - 16, gw, "CHARGE", d.matrix.energy,
        ui.pct(d.matrix.energy), ui.c.caution)
    scr:text(8 + gw, H - 16, "IN  " .. ui.si(d.matrix.input, "FE/t"),
        ui.c.ok, ui.c.panel)
    scr:text(8 + gw, H - 15, "OUT " .. ui.si(d.matrix.output, "FE/t"),
        ui.c.warn, ui.c.panel)
    scr:text(12 + 2 * gw, H - 16,
        d.ignited and "GRID: TIED" or "GRID: OPEN",
        d.ignited and ui.c.ok or ui.c.dim, ui.c.panel)

    eventLog(2, H - 12, W - 1, H - 1)
    scr:flush()
end

---------------------------------------------------------------
-- MAIN
---------------------------------------------------------------
scr:boot("FUSION FACILITY", "STEAM PLANT DISPLAY WALL", {
    "Palette", "Network link", "Render pipeline",
})
print("Steam wall online. Ctrl+T to stop.")
local tick = 0
local timer = os.startTimer(0.3)

while true do
    local event, a, b, c = os.pullEvent()
    if event == "timer" and a == timer then
        tick = tick + 1
        if tick % 2 == 0 then flash = not flash end
        if tick % 16 == 1 then
            rednet.broadcast({ type = "hello", role = "VIEW_STEAM" }, "scada_hello")
        end
        render()
        timer = os.startTimer(0.3)
    elseif event == "rednet_message" and c == "scada_state" then
        if type(b) == "table" and b.type == "state" then
            S = b
            lastSeen = os.clock()
        end
    elseif event == "rednet_message" and c == "scada_mgmt" then
        if type(b) == "table" then
            if b.type == "reboot" and (b.target == "ALL"
                or b.target == MYROLE) then
                print("remote reboot (" .. tostring(b.target) .. ")")
                sleep(0.5)
                os.reboot()
            elseif b.type == "ping" then
                local v = "?"
                if fs.exists("plant_version") then
                    local f = fs.open("plant_version", "r")
                    v = f.readAll()
                    f.close()
                end
                rednet.send(a, { type = "pong", role = MYROLE, version = v },
                    "scada_mgmt")
            end
        end
    elseif event == "monitor_resize" and a == scr.name then
        scr = ui.attach(scr.name, 0.5)
        W, H = scr.w, scr.h
    end
end
