--[[
console.lua -- Operator control panels (v3, small-monitor native)
Set role via local "role" file (RPCP or SPCP) - written by install.lua.

RPCP - reactor operator: IGNITE/SCRAM, throttle (2 mB/t per step),
       fuel gates, acknowledge, and VIEW control of the master wall.
SPCP - steam plant operator: turbine isolation lineup (drives MS/CS
       valve states on the steam one-line) and acknowledge. Isolating
       a turbine triggers the master's automatic injection RUNBACK
       (PERM INJ = online turbines x 78), so a single-turbine
       maintenance lineup is one touch. No master-wall view control.

Layouts adapt: compact for 1x2 monitors (~36x9 cells), roomy >= 16 rows.
]]

local ui = require("ui")

local CONFIG = { ROLE = "RPCP", scale = 0.5 }
if fs.exists("role") then
    local f = fs.open("role", "r")
    CONFIG.ROLE = f.readAll():gsub("%s+", "")
    f.close()
end

local scr = ui.attach(nil, CONFIG.scale)
local modem = peripheral.find("modem")
if not modem then error("Console needs a modem on the plant network", 0) end
rednet.open(peripheral.getName(modem))

local S, lastSeen = nil, -100
local MYROLE = CONFIG.ROLE
local W, H = scr.w, scr.h

local function cmd(action)
    rednet.broadcast({ type = "cmd", action = action }, "scada_cmd")
    ui.beep(11)
end

local function linked() return S and os.clock() - lastSeen < 2 end

local function header()
    scr:fill(1, 1, W, 1, ui.c.panel)
    scr:text(2, 1, CONFIG.ROLE, ui.c.accent, ui.c.panel)
    if not linked() then
        scr:text(W - 9, 1, "LINK LOSS", ui.c.alarm, ui.c.panel)
        return false
    end
    local st, sc = "STBY", ui.c.dim
    if S.igniting then st, sc = "IGNITING", ui.c.warn
    elseif S.data.ignited then st, sc = "MODE 1", ui.c.ok end
    scr:center(1, W, 1, st, sc, ui.c.panel)
    if (S.unacked or 0) > 0 then
        scr:text(W - 6, 1, "ALM" .. S.unacked, ui.c.text, ui.c.alarm)
    end
    return true
end

-- acknowledge: standing control, dim when nothing to acknowledge
local function ackButton(x1, y1, x2, y2)
    local n = S.unacked or 0
    scr:button(x1, y1, x2, y2, "ACK " .. n,
        n > 0 and ui.c.alarm or ui.c.line, "ack", true)
end

---------------------------------------------------------------
-- RPCP
---------------------------------------------------------------
local function renderRPCP()
    if not header() then scr:flush() return end
    local d = S.data
    local V = d.valves or {}
    local function st(v) return (v and v.pos and v.pos > 99) and "O"
        or ((v and v.pos and v.pos < 1) and "S" or "%") end
    local compact = H < 16

    if compact then
        -- status line: gates, injection, runback flag
        scr:text(2, 2, "D:" .. st(V.fvd) .. " T:" .. st(V.fvt), ui.c.text)
        scr:text(12, 2, "INJ " .. d.injection, ui.c.accentDim)
        if d.runback then scr:text(20, 2, "RB", ui.c.warn) end
        scr:button(W - 4, 2, W - 1, 2, "BS",
            d.battleshort and ui.c.alarm or ui.c.line, "battleshort", true)
        local half = math.floor((W - 3) / 2)
        scr:button(2, 3, 1 + half, 5, "IGNITE", ui.c.okDim, "ignite",
            not d.ignited and not S.igniting)
        scr:button(3 + half, 3, W - 1, 5, "SCRAM", ui.c.alarm, "scram",
            d.ignited)
        local q = math.floor((W - 12) / 5)
        local btns = { {"T-", "fcvDown"}, {"T+", "fcvUp"},
                       {"FD", "fvd"}, {"FT", "fvt"}, {"M1", "mode1"} }
        for i, b in ipairs(btns) do
            local x = 2 + (i - 1) * (q + 2)
            scr:button(x, 6, x + q - 1, 6, b[1], ui.c.line, b[2], true)
        end
        ackButton(2, 7, W - 1, 7)
        local vlabels = { {"C", "page:CORE"}, {"P", "page:PARAMS"},
                          {"S", "page:STEAM"}, {"A", "page:ALARMS"},
                          {"U", "page:SETUP"} }
        local vw = math.floor((W - 7) / 5)
        for i, l in ipairs(vlabels) do
            local x = 2 + (i - 1) * (vw + 1)
            scr:button(x, H - 1, x + vw - 1, H, l[1], ui.c.line, l[2], true)
        end
    else
        scr:text(2, 3, "FV-D " .. st(V.fvd) .. "  FV-T " .. st(V.fvt)
            .. "  INJ " .. d.injection .. " mB/t"
            .. (d.runback and "  RUNBACK" or ""),
            d.runback and ui.c.warn or ui.c.text)
        scr:button(W - 10, 3, W - 1, 3,
            d.battleshort and "BSHORT ON" or "BSHORT",
            d.battleshort and ui.c.alarm or ui.c.line, "battleshort", true)
        local bh = math.max(4, math.floor(H * 0.28))
        local mid = math.floor(W / 2)
        scr:button(2, 5, mid - 1, 4 + bh, "IGNITE", ui.c.okDim, "ignite",
            not d.ignited and not S.igniting)
        scr:button(mid + 1, 5, W - 1, 4 + bh, "SCRAM", ui.c.alarm, "scram",
            d.ignited)
        local vy = 6 + bh
        scr:text(2, vy, "THROTTLE (2 mB/t per step)", ui.c.accent)
        local half = math.floor((W - 6) / 2)
        scr:button(2, vy + 1, 2 + half, vy + 2, "THR -", ui.c.line,
            "fcvDown", true)
        scr:button(4 + half, vy + 1, 4 + 2 * half, vy + 2, "THR +",
            ui.c.okDim, "fcvUp", true)
        local q4 = math.floor((W - 12) / 4)
        local ty = vy + 4
        scr:button(2, ty, 2 + q4, ty + 1, "FV-D", ui.c.line, "fvd", true)
        scr:button(4 + q4, ty, 4 + 2 * q4, ty + 1, "FV-T", ui.c.line,
            "fvt", true)
        scr:button(6 + 2 * q4, ty, 6 + 3 * q4, ty + 1, "MODE1", ui.c.okDim,
            "mode1", true)
        ackButton(8 + 3 * q4, ty, W - 1, ty + 1)
        local vlabels = { {"CORE", "page:CORE"}, {"PARM", "page:PARAMS"},
                          {"STM", "page:STEAM"}, {"ALM", "page:ALARMS"},
                          {"SET", "page:SETUP"} }
        local vw = math.floor((W - 8) / 5)
        for i, l in ipairs(vlabels) do
            local x = 2 + (i - 1) * (vw + 1)
            scr:button(x, H - 2, x + vw - 1, H - 1, l[1], ui.c.line,
                l[2], true)
        end
    end
    scr:flush()
end

---------------------------------------------------------------
-- SPCP
---------------------------------------------------------------
local function renderSPCP()
    if not header() then scr:flush() return end
    local d = S.data
    local N = #d.turbines
    local nOn = 0
    for _, t in ipairs(d.turbines) do if t.online then nOn = nOn + 1 end end
    local permInj = math.min(98, nOn * 78)
    local compact = H < 16

    -- lineup summary
    scr:text(2, 2, "PERM INJ " .. permInj,
        permInj < 98 and ui.c.caution or ui.c.ok)
    scr:text(14, 2, "FLOW " .. ui.si(d.steamFlow, ""), ui.c.accentDim)
    if d.runback then scr:text(W - 8, 2, "RUNBACK", ui.c.warn) end

    -- turbine isolation tiles (touch = MS/CS lineup toggle)
    local tw = math.floor((W - 2 - N * 2) / N)
    local th = compact and (H - 6) or math.max(3, math.floor(H * 0.35))
    for i, t in ipairs(d.turbines) do
        local x1 = 2 + (i - 1) * (tw + 2)
        local state = "off"
        if not t.online then state = "alarm"
        elseif d.ignited and t.flow > 100 then state = "ok"
        elseif d.ignited then state = "warn" end
        scr:tile(x1, 3, x1 + tw, 2 + th,
            "TB-" .. i .. " " .. (t.online and ui.si(t.flow, "") or "ISO"),
            state, true)
        scr.touches[#scr.touches + 1] =
            { x1 = x1, y1 = 3, x2 = x1 + tw, y2 = 2 + th,
              action = "tb:" .. i }
    end

    if compact then
        -- first active alarm, then standing ACK
        local a = S.alarms and S.alarms[1]
        scr:text(2, H - 2, a and (a.label .. (a.acked and " [A]" or ""))
            or "NO ACTIVE ALARMS",
            a and (a.state == "alarm" and ui.c.alarm or ui.c.warn)
            or ui.c.okDim)
        ackButton(2, H - 1, W - 1, H)
    else
        local ay = 4 + th
        scr:fill(2, ay, W - 1, ay, ui.c.line)
        scr:text(3, ay, " ALARM PANEL ", ui.c.accent, ui.c.line)
        local y = ay + 1
        if S.alarms and #S.alarms > 0 then
            for _, a in ipairs(S.alarms) do
                if y > H - 4 then break end
                scr:text(3, y, a.label .. (a.acked and " [ACK]" or ""),
                    a.state == "alarm" and ui.c.alarm or ui.c.warn)
                y = y + 1
            end
        else
            scr:text(3, y, "NO ACTIVE ALARMS", ui.c.okDim)
        end
        ackButton(2, H - 2, W - 1, H - 1)
    end
    scr:flush()
end

local function render()
    scr:beginFrame()
    if CONFIG.ROLE == "SPCP" then renderSPCP() else renderRPCP() end
end

---------------------------------------------------------------
-- MAIN
---------------------------------------------------------------
scr:boot("FUSION FACILITY", CONFIG.ROLE .. " OPERATOR PANEL", {
    "Palette", "Network link", "Touch input",
})
print(CONFIG.ROLE .. " console online. Ctrl+T to stop.")
render()
local timer = os.startTimer(0.3)
local hb = 0

while true do
    local event, a, b, c = os.pullEvent()
    if event == "timer" and a == timer then
        hb = hb + 1
        if hb % 16 == 1 then
            rednet.broadcast({ type = "hello", role = CONFIG.ROLE },
                "scada_hello")
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
    elseif event == "monitor_touch" and a == scr.name then
        local action = scr:hitTest(b, c)
        if action then cmd(action) end
    elseif event == "monitor_resize" and a == scr.name then
        scr = ui.attach(scr.name, CONFIG.scale)
        W, H = scr.w, scr.h
        render()
    end
end
