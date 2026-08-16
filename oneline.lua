--[[
oneline.lua -- Center wall: MAIN STEAM & CONDENSATE ONE-LINE (6 loops)
Requires ui.lua. Monitor wall + modem on the plant network.

Style per operator reference: equipment boxes, colored process lines,
bowtie isolation valves with tag above / state below, white value
insets on lines, marching-dot flow animation on live lines.

Loops: FUSION CORE -> MS-nV1 -> MTG-n -> hot well -> CS-nV1 -> core.
Valve states follow the master's turbine isolation (SPCP controls).
Display only. Feeds from "scada_state" snapshots broadcast by hmi.lua.
]]

local ui = require("ui")

local CONFIG = { scale = 0.5 }

local scr = ui.attach(nil, CONFIG.scale)
local modem = peripheral.find("modem")
if not modem then error("One-line display needs a modem on the plant network", 0) end
rednet.open(peripheral.getName(modem))

local S, lastSeen = nil, -100
local MYROLE = "ONELINE"
local tick = 0
local W, H = scr.w, scr.h

---------------------------------------------------------------
-- STYLE WIDGETS (per reference image)
---------------------------------------------------------------
local BOWTIE = string.char(16) .. string.char(17) -- >< glyph pair

-- bowtie valve on a horizontal line: tag above, state below
local function valveH(x, y, tag, open)
    local c = open and ui.c.ok or ui.c.alarm
    scr:text(x, y, BOWTIE, c, ui.c.bg)
    scr:text(x - math.floor(#tag / 2) + 1, y - 1, tag, ui.c.accentDim)
    scr:text(x - 1, y + 1, open and "OPEN" or "SHUT", c)
end

-- white value inset box riding a line
local function inset(x, y, w, txt)
    scr:fill(x, y, x + w - 1, y, colors.white)
    txt = tostring(txt)
    if #txt > w - 2 then txt = txt:sub(1, w - 2) end
    scr:text(x + w - #txt - 1, y, txt, ui.c.bg, colors.white)
end

-- horizontal process line with optional marching flow dot
local function lineH(x1, x2, y, colour, flowing)
    scr:fill(math.min(x1, x2), y, math.max(x1, x2), y, colour)
    if flowing then
        local len = math.abs(x2 - x1)
        if len > 4 then
            local o = (tick * 2) % len
            local dx = (x2 > x1) and o or -o
            scr:px(x1 + dx, y, colors.white)
        end
    end
end

local function lineV(x, y1, y2, colour, flowing)
    scr:fill(x, math.min(y1, y2), x, math.max(y1, y2), colour)
    if flowing then
        local len = math.abs(y2 - y1)
        if len > 3 then
            local o = tick % len
            local dy = (y2 > y1) and o or -o
            scr:px(x, y1 + dy, colors.white)
        end
    end
end

local function eqBox(x1, y1, x2, y2, edge)
    scr:fill(x1, y1, x2, y2, ui.c.panel)
    scr:fill(x1, y1, x2, y1, edge)
    scr:fill(x1, y2, x2, y2, edge)
    scr:fill(x1, y1, x1, y2, edge)
    scr:fill(x2, y1, x2, y2, edge)
end

---------------------------------------------------------------
-- LAYOUT
---------------------------------------------------------------
-- left column: fuel tanks + core; trunks; six loop bands to the right
local L = {}
local function layout()
    W, H = scr.w, scr.h
    L.loopH   = math.max(8, math.floor((H - 14) / 6))
    L.firstBy = 8
    L.condX   = 31  -- condensate trunk (blue)
    L.steamX  = 34  -- main steam trunk (light)
    L.msValve = 47
    L.insetX  = 56
    L.boxX1   = 74
    L.boxX2   = math.min(126, W - 38)
    L.sgX     = L.boxX2 + 4
    L.coreY1  = 20
    L.coreY2  = math.min(44, H - 20)
end
layout()

local function loopY(i) return L.firstBy + (i - 1) * L.loopH end

---------------------------------------------------------------
-- RENDER
---------------------------------------------------------------
local function render()
    scr:beginFrame()
    if S and os.clock() - lastSeen < 2 and S.igniting then
        -- side screens go dark during light-off
        local on = (tick % 6) < 3
        scr:center(1, W, math.floor(H / 2), "IGNITION SEQUENCE IN PROGRESS",
            on and ui.c.warn or ui.c.line)
        scr:center(1, W, math.floor(H / 2) + 2, "EYES ON CENTER DISPLAY", ui.c.dim)
        scr:flush()
        return
    end
    -- header
    scr:fill(1, 1, W, 2, ui.c.panel)
    scr:text(3, 1, "FUSION FACILITY - UNIT 1", ui.c.accent, ui.c.panel)
    scr:center(1, W, 1, "MAIN STEAM & CONDENSATE ONE-LINE", ui.c.text, ui.c.panel)
    scr:text(W - 10, 1, os.date("%H:%M:%S"), ui.c.accentDim, ui.c.panel)

    if not S or os.clock() - lastSeen > 2 then
        scr:center(1, W, 2, "LINK LOSS - WAITING FOR MASTER", ui.c.alarm, ui.c.panel)
        scr:flush()
        return
    end
    local d = S.data
    local status, sc = "STANDBY", ui.c.dim
    if S.igniting then status, sc = "IGNITION SEQUENCE IN PROGRESS", ui.c.warn
    elseif d.ignited then status, sc = d.modeText or "MODE 1", ui.c.ok end
    scr:center(1, W, 2, status, sc, ui.c.panel)
    if (S.unacked or 0) > 0 and tick % 4 < 2 then
        scr:text(W - 22, 1, " ALM " .. S.unacked .. " ", ui.c.text, ui.c.alarm)
    end

    ---------------------------------------------------------
    -- fuel tanks + FV valves (top left)
    ---------------------------------------------------------
    local V = d.valves or {}
    eqBox(2, 5, 18, 8, ui.c.okDim)
    scr:center(3, 17, 6, "T DAY TANK", ui.c.text)
    scr:center(3, 17, 7, ui.pct(d.trit), ui.c.okDim)
    eqBox(2, 11, 18, 14, ui.c.okDim)
    scr:center(3, 17, 12, "D DAY TANK", ui.c.text)
    scr:center(3, 17, 13, ui.pct(d.deut), ui.c.okDim)

    local fvtOpen = V.fvt and V.fvt.pos and V.fvt.pos > 99
    local fvdOpen = V.fvd and V.fvd.pos and V.fvd.pos > 99
    local fuelFlow = d.ignited and d.injection > 0
    lineH(19, 26, 6, ui.c.ok, fuelFlow and fvtOpen)
    valveH(22, 6, "FV-T", fvtOpen)
    lineH(19, 26, 12, ui.c.ok, fuelFlow and fvdOpen)
    valveH(22, 12, "FV-D", fvdOpen)
    lineV(26, 6, L.coreY1, ui.c.ok, fuelFlow)
    inset(6, 16, 13, (d.injection / 2) .. " mB/t ea")

    ---------------------------------------------------------
    -- fusion core (left, mid) with mini plasma
    ---------------------------------------------------------
    eqBox(2, L.coreY1, 28, L.coreY2, ui.c.line)
    scr:center(3, 27, L.coreY1 + 1, "FUSION CORE", ui.c.text)
    local cx = 15
    local cy = math.floor((L.coreY1 + L.coreY2) / 2) + 1
    if d.ignited then
        local rx, ry = 9, math.max(3, math.floor((L.coreY2 - L.coreY1) / 2) - 3)
        for y = L.coreY1 + 3, L.coreY2 - 3 do
            local dy = (y - cy) / ry
            for x = 5, 25 do
                local dx = (x - cx) / rx
                local dd = math.sqrt(dx * dx + dy * dy)
                if dd <= 1.05 then
                    local t = dd + (math.random() - 0.5) * 0.16
                    if t < 0.25 then scr:px(x, y, colors.white)
                    elseif t < 0.5 then scr:px(x, y, ui.c.plasmaHot)
                    elseif t < 0.78 then scr:px(x, y, ui.c.plasma)
                    elseif t < 1.0 then scr:px(x, y, ui.c.plasmaDim) end
                end
            end
        end
    else
        scr:center(3, 27, cy, "COLD", ui.c.dim)
    end
    scr:center(3, 27, L.coreY2 - 1, "INJ " .. d.injection .. " mB/t",
        ui.c.accentDim)

    ---------------------------------------------------------
    -- trunks + loops (detailed unit blocks when 3 or fewer MTGs)
    ---------------------------------------------------------
    local N = #d.turbines
    local detailed = N <= 3
    local unitH = detailed and 16 or 0
    local loopH = detailed and (unitH + 6)
        or math.max(8, math.floor((H - 14) / math.max(N, 1)))
    local function lY(i) return L.firstBy + (i - 1) * loopH end
    local topY = lY(1)
    local botY = lY(N)
    local condBot = botY + (detailed and unitH - 2 or 4)
    local anyFlow = d.steamFlow > 100
    lineV(L.steamX, topY, botY, ui.c.steam, anyFlow)
    lineV(L.condX, topY + 4, condBot, ui.c.water, anyFlow)
    lineH(28, L.steamX, L.coreY1 + 3, ui.c.steam, anyFlow)
    lineV(L.steamX, math.min(L.coreY1 + 3, topY), math.max(L.coreY1 + 3, topY),
        ui.c.steam, false)
    lineV(L.condX, L.coreY2 - 3, condBot, ui.c.water, false)
    lineH(L.condX, 28, L.coreY2 - 3, ui.c.water, anyFlow)
    scr:text(L.steamX + 2, topY - 2, "MAIN STEAM", ui.c.steam)
    scr:text(L.condX - 10, condBot + 1, "CONDENSATE", ui.c.water)

    for i, t in ipairs(d.turbines) do
        local by = lY(i)
        local open = t.online
        local flowing = open and t.flow > 100
        lineH(L.steamX, L.boxX1, by, ui.c.steam, flowing)
        valveH(L.msValve, by, "MS-" .. i .. "V1", open)
        inset(L.insetX, by - 1, 14, ui.si(t.flow, "mB/t"))

        local tbLoi = S.loi and S.loi["NODE_TB" .. i]
        local status2, sc2 = "ONLINE", ui.c.ok
        if not t.online then status2, sc2 = "ISOLATED", ui.c.alarm
        elseif d.ignited and t.flow < 100 then status2, sc2 = "TRIPPED", ui.c.warn
        elseif not d.ignited then status2, sc2 = "STANDBY", ui.c.dim end
        if tbLoi then status2, sc2 = "LOI", ui.c.line end

        if detailed then
            -- big unit detail block
            local bx2 = math.min(W - 3, L.boxX2 + 32)
            local byy2 = by + unitH - 4
            eqBox(L.boxX1, by - 1, bx2, byy2, sc2)
            scr:text(L.boxX1 + 2, by, "MTG-" .. i, ui.c.text)
            scr:fill(L.boxX1 + 10, by, L.boxX1 + 11 + #status2, by, sc2)
            scr:text(L.boxX1 + 11, by, status2, ui.c.bg, sc2)
            if t.live then
                scr:text(L.boxX1 + 13 + #status2, by, "LIVE", ui.c.accent)
            end
            local ix = L.boxX1 + 2
            if tbLoi then
                scr:text(ix, by + 2, "STEAM FLOW", ui.c.accentDim)
                scr:loiBox(ix + 12, by + 2, 12)
                scr:text(ix + 28, by + 2, "GEN OUTPUT", ui.c.accentDim)
                scr:loiBox(ix + 40, by + 2, 12)
                scr:text(ix, by + 4, "STEAM TANK", ui.c.accentDim)
                scr:loiBox(ix + 12, by + 4, 6)
                scr:text(ix + 28, by + 4, "GEN BUFFER", ui.c.accentDim)
                scr:loiBox(ix + 40, by + 4, 6)
                scr:text(ix, by + 6, "SG LEVEL", ui.c.accentDim)
                scr:loiBox(ix + 12, by + 6, 34, "LOSS OF INDICATION")
                scr:text(ix, by + 8, "HOT WELL RETURN", ui.c.accentDim)
                scr:loiBox(ix + 17, by + 8, 12)
            else
            scr:text(ix, by + 2, "STEAM FLOW", ui.c.accentDim)
            scr:text(ix + 12, by + 2, ui.si(t.flow, "mB/t"), ui.c.steam)
            scr:text(ix + 28, by + 2, "GEN OUTPUT", ui.c.accentDim)
            scr:text(ix + 40, by + 2, ui.si(t.prod, "FE/t"), ui.c.caution)
            scr:text(ix, by + 4, "STEAM TANK", ui.c.accentDim)
            scr:text(ix + 12, by + 4, ui.pct(t.steamPct), ui.c.text)
            scr:text(ix + 28, by + 4, "GEN BUFFER", ui.c.accentDim)
            scr:text(ix + 40, by + 4, ui.pct(t.buffer), ui.c.text)
            scr:text(ix + 48, by + 4, t.mode or "", ui.c.dim)
            scr:text(ix, by + 6, "SG LEVEL", ui.c.accentDim)
            if t.water == nil then
                scr:loiBox(ix + 12, by + 6, 34, "NO HOT WELL INSTRUMENT")
            else
                scr:bandBar(ix + 12, by + 6, 34, t.water, 0.40, 0.70)
                scr:text(ix + 48, by + 6, ui.pct(t.water),
                    t.water < 0.25 and ui.c.alarm or ui.c.text)
            end
            scr:text(ix, by + 8, "HOT WELL RETURN", ui.c.accentDim)
            scr:text(ix + 17, by + 8,
                open and ui.si(t.flow, "mB/t") or "ISOLATED",
                open and ui.c.water or ui.c.alarm)
            end
            -- condensate return
            local cyy = byy2 + 2
            lineV(L.boxX1 + 4, byy2 + 1, cyy, ui.c.water, flowing)
            lineH(L.boxX1 + 4, L.condX, cyy, ui.c.water, flowing) -- toward trunk
            valveH(L.msValve, cyy, "CS-" .. i .. "V1", open)
            inset(L.insetX, cyy + 1, 14, ui.si(open and t.flow or 0, "mB/t"))
        else
            eqBox(L.boxX1, by - 1, L.boxX2, by + 2, sc2)
            scr:text(L.boxX1 + 2, by, "MTG-" .. i, ui.c.text)
            scr:text(L.boxX1 + 10, by, status2, sc2)
            scr:text(L.boxX1 + 2, by + 1, ui.si(t.prod, "FE/t"), ui.c.caution)
            scr:bandBar(L.sgX, by, 18, t.water or 0, 0.40, 0.70)
            scr:text(L.sgX + 20, by, ui.pct(t.water or 0), ui.c.text)
            local cyy = by + 4
            lineV(L.boxX1 + 4, by + 3, cyy, ui.c.water, flowing)
            lineH(L.boxX1 + 4, L.condX, cyy, ui.c.water, flowing)
            valveH(L.msValve, cyy, "CS-" .. i .. "V1", open)
            inset(L.insetX, cyy + 1, 14, ui.si(open and t.flow or 0, "mB/t"))
        end
    end

    ---------------------------------------------------------
    -- footer
    ---------------------------------------------------------
    scr:fill(1, H - 2, W, H, ui.c.panel)
    local totalFlow, totalProd = 0, 0
    for _, t in ipairs(d.turbines) do
        totalFlow = totalFlow + t.flow
        totalProd = totalProd + t.prod
    end
    scr:text(3, H - 1, "TOTAL STEAM " .. ui.si(totalFlow, "mB/t"),
        ui.c.steam, ui.c.panel)
    scr:text(32, H - 1, "GROSS " .. ui.si(totalProd + (d.passiveGen or 0), "FE/t"),
        ui.c.caution, ui.c.panel)
    scr:center(1, W, H, "DISPLAY ONLY - ISOLATIONS AT SPCP", ui.c.accentDim,
        ui.c.panel)
    local n = 0
    for _, t in ipairs(d.turbines) do if t.online then n = n + 1 end end
    local permInj = math.min(98, n * 78)
    scr:text(W - 26, H - 1, "PERM INJ " .. permInj .. " mB/t",
        permInj < 98 and ui.c.caution or ui.c.ok, ui.c.panel)

    scr:flush()
end

---------------------------------------------------------------
-- MAIN
---------------------------------------------------------------
scr:boot("FUSION FACILITY", "MAIN STEAM ONE-LINE DISPLAY", {
    "Palette", "Network link", "Loop renderer",
})
print("One-line display online. Ctrl+T to stop.")
math.randomseed(os.epoch("utc"))
local timer = os.startTimer(0.25)

while true do
    local event, a, b, c = os.pullEvent()
    if event == "timer" and a == timer then
        tick = tick + 1
        if tick % 20 == 1 then
            rednet.broadcast({ type = "hello", role = "ONELINE" }, "scada_hello")
        end
        render()
        timer = os.startTimer(0.25)
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
        scr = ui.attach(scr.name, CONFIG.scale)
        layout()
    end
end
