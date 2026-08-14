--[[
primary.lua -- CENTER WALL: PRIMARY PLANT ONE-LINE
Requires ui.lua. Monitor wall + modem on the plant network.

Reactor-side big board: five fuel-train tanks with levels, D/T
production-vs-burn margins, fuel valves FV-D/FV-T/FCV live, the core,
makeup water path, a REACTOR PROTECTION SYSTEM channel panel with
first-out annunciation, and the active-alarm strip.

Display only. Feeds from "scada_state" snapshots (hmi.lua master).
]]

local ui = require("ui")

local scr = ui.attach(nil, 0.5)
local modem = peripheral.find("modem")
if not modem then error("Primary display needs a modem on the plant network", 0) end
rednet.open(peripheral.getName(modem))

local S, lastSeen = nil, -100
local tick = 0
local W, H = scr.w, scr.h
local lastStage, stageTick = nil, 0

-- mega digits for the countdown (each font pixel = 4x2 cells)
local MEGA = {
    ["0"]={"111","101","101","101","111"}, ["1"]={"010","110","010","010","111"},
    ["2"]={"111","001","111","100","111"}, ["3"]={"111","001","111","001","111"},
    ["4"]={"101","101","111","001","001"}, ["5"]={"111","100","111","001","111"},
    ["6"]={"111","100","111","101","111"}, ["7"]={"111","001","010","010","010"},
    ["8"]={"111","101","111","101","111"}, ["9"]={"111","101","111","001","111"},
}
local function megaNum(x, y, s2, colour)
    local cx2 = x
    for i = 1, #s2 do
        local g = MEGA[s2:sub(i, i)]
        if g then
            for r = 1, 5 do
                for c2 = 1, 3 do
                    if g[r]:sub(c2, c2) == "1" then
                        scr:fill(cx2 + (c2 - 1) * 4, y + (r - 1) * 2,
                            cx2 + (c2 - 1) * 4 + 3, y + (r - 1) * 2 + 1, colour)
                    end
                end
            end
            cx2 = cx2 + 14
        end
    end
end

-- full-bleed ignition cinematic (center wall becomes the show)
local function renderIgnition(d)
    local seq = S.seq or { stage = "checks" }
    if seq.stage ~= lastStage then lastStage = seq.stage; stageTick = 0 end
    stageTick = stageTick + 1
    local midY = math.floor(H / 2)
    local frameC = (seq.stage == "fire" or seq.stage == "ignition"
        or seq.stage == "countdown")
        and ((tick % 2 == 0) and ui.c.alarm or ui.c.warnDim) or ui.c.line
    scr:fill(1, 1, W, 1, frameC); scr:fill(1, H, W, H, frameC)
    scr:fill(1, 1, 1, H, frameC); scr:fill(W, 1, W, H, frameC)

    if seq.stage == "closeout" then
        scr:center(1, W, midY - 6, "REACTOR COMPARTMENT CLOSE OUT", ui.c.warn)
        scr:center(1, W, midY - 3, seq.info or "", ui.c.text)
        scr:center(1, W, midY + 5, "ALL PERSONNEL VACATE THE COMPARTMENT",
            (tick % 4 < 2) and ui.c.caution or ui.c.dim)
    elseif seq.stage == "checks" then
        scr:center(1, W, midY - 2, "PRE-START CHECKS IN PROGRESS", ui.c.accent)
        scr:center(1, W, midY, "VERIFYING PLANT LINEUP"
            .. string.rep(".", stageTick % 4), ui.c.dim)
    elseif seq.stage == "charging" then
        scr:center(1, W, 7, "*** LASER BANKS CHARGING ***",
            (tick % 2 == 0) and ui.c.warn or ui.c.caution)
        local bw2 = math.floor(W * 0.55)
        local x0 = math.floor((W - bw2) / 2)
        for i = 1, 4 do
            local frac = (d.lasers and d.lasers[i]) or 0
            local y = midY - 10 + i * 5
            scr:text(x0 - 9, y, "BANK " .. string.char(64 + i),
                (seq.info == string.char(64 + i)) and ui.c.caution or ui.c.dim)
            scr:fill(x0, y, x0 + bw2 - 1, y + 1, ui.c.panel)
            local f = math.floor(bw2 * frac + 0.5)
            if f > 0 then
                scr:fill(x0, y, x0 + f - 1, y + 1,
                    frac >= 0.99 and ui.c.ok or ui.c.caution)
            end
            scr:text(x0 + bw2 + 2, y, ui.pct(frac), ui.c.text)
        end
    elseif seq.stage == "alignment" then
        scr:center(1, W, 7, "FOCUS MATRIX ALIGNMENT", ui.c.accent)
        local cx2, cy2 = math.floor(W / 2), midY + 2
        local off = math.max(2, 26 - stageTick * 2)
        for _, p in ipairs({{-1,-1},{1,-1},{-1,1},{1,1}}) do
            local bx = cx2 + p[1] * off * 2
            local by2 = cy2 + p[2] * off
            scr:fill(math.min(bx - p[1] * 3, bx), by2,
                math.max(bx - p[1] * 3, bx), by2, ui.c.accent)
            scr:fill(bx, math.min(by2, by2 + p[2]), bx,
                math.max(by2, by2 + p[2]), ui.c.accent)
        end
        if off <= 2 then
            scr:center(1, W, cy2, "TARGET LOCK",
                (tick % 2 == 0) and ui.c.ok or colors.white)
        end
    elseif seq.stage == "injection" then
        scr:center(1, W, midY - 5, "D-T INJECTORS PRESSURIZING", ui.c.ok)
        local V = d.valves or {}
        scr:center(1, W, midY - 1, ("FV-D %3d%%    FV-T %3d%%    FCV %3d%%"):format(
            (V.fvd and V.fvd.pos) or 0, (V.fvt and V.fvt.pos) or 0,
            (V.fcv and V.fcv.pos) or 0), ui.c.text)
        scr:center(1, W, midY + 3, "FUEL VALVE LINEUP IN PROGRESS",
            (tick % 4 < 2) and ui.c.caution or ui.c.dim)
    elseif seq.stage == "countdown" then
        local n = tostring(seq.info or "")
        scr:center(1, W, 9, "IGNITION IN",
            (tick % 2 == 0) and ui.c.warn or colors.white)
        megaNum(math.floor(W / 2) - math.floor(#n * 14 / 2), midY - 5, n,
            (tick % 2 == 0) and ui.c.alarm or colors.white)
        scr:center(1, W, H - 6, "ALL STATIONS STANDBY FOR IGNITION",
            (tick % 4 < 2) and ui.c.caution or ui.c.dim)
    elseif seq.stage == "fire" then
        local cx2, cy2 = math.floor(W / 2), midY
        local prog = math.min(1, stageTick / 8)
        for _, c2 in ipairs({{3,3},{W-2,3},{3,H-2},{W-2,H-2}}) do
            local ex = c2[1] + (cx2 - c2[1]) * prog
            local ey = c2[2] + (cy2 - c2[2]) * prog
            for s2 = 0, 24 do
                scr:px(math.floor(c2[1] + (ex - c2[1]) * s2 / 24 + 0.5),
                    math.floor(c2[2] + (ey - c2[2]) * s2 / 24 + 0.5),
                    (s2 > 20) and colors.white or ui.c.alarm)
            end
        end
        scr:center(1, W, 5, "LASERS FIRING",
            (tick % 2 == 0) and colors.white or ui.c.alarm)
    elseif seq.stage == "ignition" then
        if tick % 2 == 0 then
            scr:fill(2, 2, W - 1, H - 1, ui.c.plasmaHot)
            scr:center(2, W - 1, midY, "IGNITION", ui.c.bg, ui.c.plasmaHot)
        else
            local cx2, cy2 = math.floor(W / 2), midY
            local r = stageTick * 2
            for a2 = 0, 79 do
                local ang = a2 / 80 * math.pi * 2
                scr:px(cx2 + math.floor(math.cos(ang) * r * 2),
                    cy2 + math.floor(math.sin(ang) * r), ui.c.plasma)
                scr:px(cx2 + math.floor(math.cos(ang) * r * 1.4),
                    cy2 + math.floor(math.sin(ang) * r * 0.7), ui.c.plasmaHot)
            end
            scr:center(1, W, midY, "IGNITION", colors.white)
        end
    else -- stable
        local cx2, cy2 = math.floor(W / 2), midY
        local rx2 = math.floor(W * 0.2)
        local ry2 = midY - 6
        for y = 6, H - 6 do
            local dy = (y - cy2) / ry2
            for x = cx2 - rx2 - 8, cx2 + rx2 + 8 do
                local dx = (x - cx2) / rx2
                local dd = math.sqrt(dx * dx + dy * dy)
                if dd <= 1.05 then
                    local t2 = dd + (math.random() - 0.5) * 0.15
                    if t2 < 0.25 then scr:px(x, y, colors.white)
                    elseif t2 < 0.5 then scr:px(x, y, ui.c.plasmaHot)
                    elseif t2 < 0.8 then scr:px(x, y, ui.c.plasma)
                    elseif t2 < 1.0 then scr:px(x, y, ui.c.plasmaDim) end
                end
            end
        end
        scr:center(1, W, H - 4, "PLASMA STABLE - POWER ASCENSION",
            (tick % 2 == 0) and ui.c.ok or colors.white)
    end
end

local BOWTIE = string.char(16) .. string.char(17)

local function valveH(x, y, tag, open, pos)
    local c = open and ui.c.ok or ui.c.alarm
    local st = open and "OPEN" or "SHUT"
    if pos and pos > 1 and pos < 99 then
        c = ui.c.caution
        st = math.floor(pos) .. "%"
    end
    scr:text(x, y, BOWTIE, c, ui.c.bg)
    scr:text(x - math.floor(#tag / 2) + 1, y - 1, tag, ui.c.accentDim)
    scr:text(x - 1, y + 1, st, c)
end

local function inset(x, y, w, txt)
    scr:fill(x, y, x + w - 1, y, colors.white)
    txt = tostring(txt)
    if #txt > w - 2 then txt = txt:sub(1, w - 2) end
    scr:text(x + w - #txt - 1, y, txt, ui.c.bg, colors.white)
end

local function lineH(x1, x2, y, colour, flowing)
    scr:fill(math.min(x1, x2), y, math.max(x1, x2), y, colour)
    if flowing then
        local len = math.abs(x2 - x1)
        if len > 4 then scr:px(math.min(x1, x2) + (tick * 2) % len, y, colors.white) end
    end
end

local function lineV(x, y1, y2, colour, flowing)
    scr:fill(x, math.min(y1, y2), x, math.max(y1, y2), colour)
    if flowing then
        local len = math.abs(y2 - y1)
        if len > 3 then scr:px(x, math.min(y1, y2) + tick % len, colors.white) end
    end
end

local function tankBox(x1, y1, name, frac, colour)
    local x2, y2 = x1 + 28, y1 + 4
    scr:fill(x1, y1, x2, y2, ui.c.panel)
    scr:fill(x1, y1, x2, y1, colour)
    scr:text(x1 + 1, y1, " " .. name .. " ", ui.c.text, colour)
    scr:fill(x1 + 2, y1 + 2, x2 - 2, y1 + 2, ui.c.bg)
    local f = math.floor((x2 - x1 - 3) * (frac or 0) + 0.5)
    if f > 0 then scr:fill(x1 + 2, y1 + 2, x1 + 1 + f, y1 + 2, colour) end
    scr:text(x1 + 2, y1 + 3, ui.pct(frac or 0), ui.c.text, ui.c.panel)
    return y2
end

---------------------------------------------------------------
-- RENDER
---------------------------------------------------------------
local function render()
    scr:beginFrame()
    if S and os.clock() - lastSeen < 2 and S.igniting then
        renderIgnition(S.data)
        scr:flush()
        return
    end
    scr:fill(1, 1, W, 2, ui.c.panel)
    scr:text(3, 1, "FUSION FACILITY - UNIT 1", ui.c.accent, ui.c.panel)
    scr:center(1, W, 1, "PRIMARY PLANT ONE-LINE", ui.c.text, ui.c.panel)
    scr:text(W - 10, 1, os.date("%H:%M:%S"), ui.c.accentDim, ui.c.panel)
    if not S or os.clock() - lastSeen > 2 then
        scr:center(1, W, math.floor(H / 2), "LINK LOSS - WAITING FOR MASTER",
            ui.c.alarm, ui.c.bg)
        scr:flush()
        return
    end
    local d = S.data
    local status, sc = "STANDBY", ui.c.dim
    if S.igniting then status, sc = "IGNITION SEQUENCE IN PROGRESS", ui.c.warn
    elseif d.ignited then status, sc = "MODE 1 - POWER OPERATION", ui.c.ok end
    scr:center(1, W, 2, status, sc, ui.c.panel)
    if (S.unacked or 0) > 0 and tick % 4 < 2 then
        scr:text(W - 22, 1, " ALM " .. S.unacked .. " ", ui.c.text, ui.c.alarm)
    end

    local tk = d.tanks or {}
    local burn = d.injection / 2
    local L2 = S.loi or {}
    local rxLoi, tkLoi, fuelLoi = L2.NODE_REACTOR, L2.NODE_TANKS, L2.NODE_FUEL

    ---------------------------------------------------------
    -- left column: five tanks
    ---------------------------------------------------------
    scr:text(2, 4, "FUEL TRAIN STORAGE", ui.c.accent)
    if tkLoi then
        for i2, nm in ipairs({ "LIQ LITHIUM", "HEAVY WATER", "WATER STG",
                               "DEUTERIUM", "TRITIUM" }) do
            local ty2 = 5 + (i2 - 1) * 6
            scr:fill(2, ty2, 30, ty2 + 4, ui.c.panel)
            scr:text(3, ty2, " " .. nm .. " ", ui.c.text, ui.c.line)
            scr:loiBox(4, ty2 + 2, 24, "LOI")
        end
    else
        tankBox(2, 5,  "LIQ LITHIUM", tk.li, ui.c.plasmaDim)
        tankBox(2, 11, "HEAVY WATER", tk.hw, ui.c.accentDim)
        tankBox(2, 17, "WATER STG",   tk.stor, ui.c.water)
        tankBox(2, 23, "DEUTERIUM",   d.deut, ui.c.accent)
        tankBox(2, 29, "TRITIUM",     d.trit, ui.c.ok)
    end

    ---------------------------------------------------------
    -- production vs burn margins
    ---------------------------------------------------------
    scr:panel(34, 5, 62, 20, "PRODUCTION / BURN")
    local pD, pT = d.prodD or 0, d.prodT or 0
    if fuelLoi then pD, pT = nil, nil end
    local mD = pD and (pD - burn) or nil
    local mT = pT and (pT - burn) or nil
    scr:text(36, 7, "DEUTERIUM", ui.c.accent, ui.c.panel)
    if not pD then scr:loiBox(36, 8, 12, "LOI")
    else
    scr:text(36, 8,  "PROD " .. string.format("%5.1f", pD), ui.c.text, ui.c.panel)
    end
    scr:text(36, 9,  "BURN " .. string.format("%5.1f", burn), ui.c.dim, ui.c.panel)
    if mD then
        scr:text(36, 10, "MARG " .. string.format("%+5.1f", mD),
            mD >= 0 and ui.c.ok or ui.c.alarm, ui.c.panel)
    end
    scr:text(36, 13, "TRITIUM", ui.c.ok, ui.c.panel)
    if not pT then scr:loiBox(36, 14, 12, "LOI")
    else
    scr:text(36, 14, "PROD " .. string.format("%5.1f", pT), ui.c.text, ui.c.panel)
    end
    scr:text(36, 15, "BURN " .. string.format("%5.1f", burn), ui.c.dim, ui.c.panel)
    if mT then
        scr:text(36, 16, "MARG " .. string.format("%+5.1f", mT),
            mT >= 0 and ui.c.ok or ui.c.alarm, ui.c.panel)
    end
    scr:text(36, 18, "mB/t", ui.c.dim, ui.c.panel)

    ---------------------------------------------------------
    -- fuel lines: D/T tanks -> FV valves -> FCV -> core
    ---------------------------------------------------------
    local V = d.valves or {}
    local fvdOpen = V.fvd and V.fvd.pos and V.fvd.pos > 99
    local fvtOpen = V.fvt and V.fvt.pos and V.fvt.pos > 99
    local fueling = d.ignited and d.injection > 0
    -- from D tank (y=25) and T tank (y=31)
    lineH(31, 66, 25, ui.c.accent, fueling and fvdOpen)
    valveH(50, 25, "FV-D", fvdOpen, V.fvd and V.fvd.pos)
    inset(56, 24, 9, burn .. "mB/t")
    lineH(31, 66, 31, ui.c.ok, fueling and fvtOpen)
    valveH(50, 31, "FV-T", fvtOpen, V.fvt and V.fvt.pos)
    inset(56, 30, 9, burn .. "mB/t")
    lineV(66, 25, 31, ui.c.okDim, false)
    lineH(66, 74, 28, ui.c.okDim, fueling)
    local fcvOpen = V.fcv and V.fcv.pos and V.fcv.pos > 1
    valveH(70, 28, "FCV-1", fcvOpen, V.fcv and V.fcv.pos)
    inset(56, 34, 18, "INJ " .. d.injection .. " mB/t")

    ---------------------------------------------------------
    -- core (center-right) + makeup water
    ---------------------------------------------------------
    local cx1, cy1, cx2, cy2 = 75, 8, 112, 42
    scr:fill(cx1, cy1, cx2, cy2, ui.c.panel)
    scr:fill(cx1, cy1, cx2, cy1, ui.c.line)
    scr:fill(cx1, cy2, cx2, cy2, ui.c.line)
    scr:fill(cx1, cy1, cx1, cy2, ui.c.line)
    scr:fill(cx2, cy1, cx2, cy2, ui.c.line)
    scr:center(cx1, cx2, cy1 + 1, "FUSION CORE", ui.c.text, ui.c.panel)
    local ccx, ccy = math.floor((cx1 + cx2) / 2), math.floor((cy1 + cy2) / 2) + 1
    if d.ignited then
        for y = cy1 + 3, cy2 - 3 do
            local dy = (y - ccy) / (math.floor((cy2 - cy1) / 2) - 3)
            for x = cx1 + 4, cx2 - 4 do
                local dx = (x - ccx) / (math.floor((cx2 - cx1) / 2) - 4)
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
        scr:center(cx1, cx2, ccy, "COLD", ui.c.dim, ui.c.panel)
    end
    if rxLoi then
        scr:loiBox(cx1 + 4, cy2 - 1, cx2 - cx1 - 8, "PLASMA / CASE - LOI")
    else
        scr:center(cx1, cx2, cy2 - 1, "PLASMA " .. ui.si(d.plasmaTemp, "K")
            .. "  CASE " .. ui.si(d.caseTemp, "K"), ui.c.accentDim, ui.c.panel)
    end
    -- makeup water from storage tank
    lineH(31, 60, 21, ui.c.water, d.ignited)
    lineV(60, 21, 40, ui.c.water, false)
    lineH(60, cx1, 40, ui.c.water, d.ignited)
    scr:text(33, 20, "MAKEUP / FEED", ui.c.water)
    -- steam off to the right wall
    lineH(cx2, W - 4, 24, ui.c.steam, d.ignited and d.steamFlow > 100)
    scr:text(W - 30, 23, "STEAM " .. ui.si(d.steamFlow, "mB/t"), ui.c.steam)
    scr:text(W - 30, 25, "TO TURBINE HALL", ui.c.accentDim)

    ---------------------------------------------------------
    -- RPS panel (right)
    ---------------------------------------------------------
    scr:panel(116, 4, W - 1, 20, "REACTOR PROTECTION SYSTEM")
    local tripped = false
    local st = {}
    for _, a in ipairs(S.alarms or {}) do st[a.id] = a.state end
    if st.SCRAM or st.FLAMEOUT then tripped = true end
    if tripped and tick % 2 == 0 then
        scr:fill(118, 6, W - 3, 7, ui.c.alarm)
        scr:center(118, W - 3, 6, "** RPS TRIPPED **", ui.c.text, ui.c.alarm)
    else
        scr:center(118, W - 3, 6, tripped and "** RPS TRIPPED **" or "RPS NORMAL",
            tripped and ui.c.alarm or ui.c.ok, ui.c.panel)
    end
    local channels = {
        { "RT-1 FUEL FEED",   st.DT_LO or st.TPROD },
        { "RT-2 RX WATER",    st.WTR_LO },
        { "RT-3 STEAM PRESS", st.STM_HI },
        { "RT-4 HEAT SINK",   st.TB_TRIP or st.FLOW_LO },
        { "RT-5 CASE TEMP",   st.CST_HI },
        { "RT-6 SG LEVEL",    st.SG_LVL },
    }
    for i, ch in ipairs(channels) do
        local y = 7 + i
        scr:text(118, y, ch[1], ui.c.dim, ui.c.panel)
        local state, c2 = "OK", ui.c.ok
        if ch[2] == "alarm" then state, c2 = "TRIP", ui.c.alarm
        elseif ch[2] == "warn" then state, c2 = "PRE-TRIP", ui.c.warn end
        scr:text(W - 3 - #state, y, state, c2, ui.c.panel)
    end
    scr:text(118, 15, "FIRST OUT:", ui.c.accentDim, ui.c.panel)
    scr:text(118, 16, S.firstOut or "NONE",
        S.firstOut and ui.c.alarm or ui.c.dim, ui.c.panel)
    scr:text(118, 18, "PERM INJ " .. (function()
        local n = 0
        for _, t in ipairs(d.turbines) do if t.online then n = n + 1 end end
        return math.min(98, n * 78)
    end)() .. " mB/t", ui.c.text, ui.c.panel)

    ---------------------------------------------------------
    -- laser banks + hohlraum readiness (right, below RPS)
    ---------------------------------------------------------
    scr:panel(116, 22, W - 1, 32, "IGNITION READINESS")
    for i = 1, 4 do
        local frac = (d.lasers and d.lasers[i]) or 0
        scr:gaugeH(118, 22 + i * 2, W - 121, "BANK " .. string.char(64 + i),
            frac, ui.pct(frac), frac >= 0.99 and ui.c.ok or ui.c.caution)
    end
    scr:text(118, 31, "HOHLRAUM: " .. (d.hohlraum and "LOADED" or "EMPTY"),
        d.hohlraum and ui.c.ok or ui.c.alarm, ui.c.panel)

    ---------------------------------------------------------
    -- active alarm strip
    ---------------------------------------------------------
    scr:panel(2, H - 18, W - 1, H - 3, "ACTIVE ALARMS / EVENTS")
    local y = H - 16
    if S.alarms and #S.alarms > 0 then
        for _, a in ipairs(S.alarms) do
            if y > H - 11 then break end
            local c2 = a.state == "alarm" and (a.acked and ui.c.warn or ui.c.alarm)
                or ui.c.warn
            scr:text(4, y, a.label .. " [" .. a.state:upper() .. "]"
                .. (a.acked and " ACK" or ""), c2, ui.c.panel)
            y = y + 1
        end
    else
        scr:text(4, y, "NO ACTIVE ALARMS", ui.c.okDim, ui.c.panel)
        y = y + 1
    end
    y = H - 10
    scr:fill(4, y - 1, W - 4, y - 1, ui.c.line)
    for i = 1, math.min(#(S.log or {}), 6) do
        local e = S.log[i]
        scr:text(4, y, e.time .. "  " .. e.text, e.colour or ui.c.dim, ui.c.panel)
        y = y + 1
    end

    scr:fill(1, H - 1, W, H, ui.c.panel)
    scr:center(1, W, H, "DISPLAY ONLY - FUEL CONTROL AT RPCP", ui.c.accentDim,
        ui.c.panel)
    scr:flush()
end

---------------------------------------------------------------
-- MAIN
---------------------------------------------------------------
scr:boot("FUSION FACILITY", "PRIMARY PLANT ONE-LINE", {
    "Palette", "Network link", "RPS panel", "Fuel train",
})
print("Primary display online. Ctrl+T to stop.")
math.randomseed(os.epoch("utc"))
local timer = os.startTimer(0.25)

while true do
    local event, a, b, c = os.pullEvent()
    if event == "timer" and a == timer then
        tick = tick + 1
        if tick % 20 == 1 then
            rednet.broadcast({ type = "hello", role = "PRIMARY" }, "scada_hello")
        end
        render()
        timer = os.startTimer(0.25)
    elseif event == "rednet_message" and c == "scada_state" then
        if type(b) == "table" and b.type == "state" then
            S = b
            lastSeen = os.clock()
        end
    elseif event == "monitor_resize" and a == scr.name then
        scr = ui.attach(scr.name, 0.5)
        W, H = scr.w, scr.h
    end
end
