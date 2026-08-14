--[[
console.lua -- Operator control panel (RPCP / SPCP), controls-only layout
Requires ui.lua. Small monitor + modem on the plant network.

Set CONFIG.ROLE = "RPCP" or "SPCP" below.
CONFIG.scale: 0.5 default; set to 1 for double-size text if your
console monitor is at least ~4x3 (fewer cells, bigger buttons).

Data lives on the walls; this panel is deliberately sparse: one
status line + large touch controls. Commands go to the master.
]]

local ui = require("ui")

local CONFIG = {
    ROLE  = "RPCP",   -- "RPCP" or "SPCP"
    scale = 0.5,
}

-- per-computer role lives in a local file the updater never touches:
-- put RPCP or SPCP (one word) in a file named "role" on this computer.
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
        scr:text(W - 10, 1, "LINK LOSS", ui.c.alarm, ui.c.panel)
        return false
    end
    local status, sc = "STANDBY", ui.c.dim
    if S.igniting then status, sc = "IGNITING", ui.c.warn
    elseif S.data.ignited then status, sc = "MODE 1", ui.c.ok end
    scr:center(1, W, 1, status, sc, ui.c.panel)
    if (S.unacked or 0) > 0 then
        scr:text(W - 8, 1, "ALM " .. S.unacked, ui.c.text, ui.c.alarm)
    end
    return true
end

-- shared VIEW row: switches the master wall's page (2 rows tall)
local function viewRow(y)
    local labels = { {"CORE", "page:CORE"}, {"PARM", "page:PARAMS"},
                     {"STM", "page:STEAM"}, {"ALM", "page:ALARMS"},
                     {"SET", "page:SETUP"} }
    local bw = math.floor((W - 8) / 5)
    for i, l in ipairs(labels) do
        local x = 2 + (i - 1) * (bw + 1)
        scr:button(x, y, x + bw - 1, y + 1, l[1], ui.c.line, l[2], true)
    end
end

local function renderRPCP()
    if not header() then scr:flush() return end
    local d = S.data
    local V = d.valves or {}
    local function vtxt(v)
        if not v then return "?" end
        if v.pos > 99 then return "OPEN"
        elseif v.pos < 1 then return "SHUT" end
        return math.floor(v.pos) .. "%"
    end
    -- one status line only; details live on the walls
    scr:text(2, 3, "FV-D", ui.c.dim)
    scr:text(7, 3, vtxt(V.fvd),
        (V.fvd and V.fvd.pos > 99) and ui.c.ok or ui.c.alarm)
    scr:text(13, 3, "FV-T", ui.c.dim)
    scr:text(18, 3, vtxt(V.fvt),
        (V.fvt and V.fvt.pos > 99) and ui.c.ok or ui.c.alarm)
    scr:text(24, 3, "FCV " .. vtxt(V.fcv), ui.c.text)
    scr:text(34, 3, "INJ " .. d.injection, ui.c.accentDim)

    -- big paired controls
    local mid = math.floor(W / 2)
    local bh = math.max(4, math.floor(H * 0.28))
    scr:button(2, 5, mid - 1, 4 + bh, "IGNITE", ui.c.okDim, "ignite",
        not d.ignited and not S.igniting)
    scr:button(mid + 1, 5, W - 1, 4 + bh, "SCRAM", ui.c.alarm, "scram", d.ignited)

    local vy = 6 + bh
    local bw = math.floor((W - 10) / 4)
    local vlabels = { {"FV-D", "fvd"}, {"FV-T", "fvt"},
                      {"FCV-", "fcvDown"}, {"FCV+", "fcvUp"} }
    for i, l in ipairs(vlabels) do
        local x = 2 + (i - 1) * (bw + 2)
        scr:button(x, vy, x + bw - 1, vy + 1, l[1], ui.c.line, l[2], true)
    end
    local ackC = (S.unacked or 0) > 0 and ui.c.alarm or ui.c.warnDim
    scr:button(2, vy + 3, W - 1, vy + 4,
        "ACKNOWLEDGE ALARMS (" .. (S.unacked or 0) .. ")", ackC, "ack", true)
    viewRow(H - 2)
    scr:flush()
end

local function renderSPCP()
    if not header() then scr:flush() return end
    local d = S.data
    -- turbine isolation tiles across the top (sized to unit count)
    local N = #d.turbines
    local tw = math.floor((W - 2 - N * 2) / N)
    local th = math.max(3, math.floor(H * 0.22))
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
            { x1 = x1, y1 = 3, x2 = x1 + tw, y2 = 2 + th, action = "tb:" .. i }
    end
    -- alarm control panel
    local ay = 4 + th
    scr:fill(2, ay, W - 1, ay, ui.c.line)
    scr:text(3, ay, " ALARM PANEL ", ui.c.accent, ui.c.line)
    local y = ay + 1
    if S.alarms and #S.alarms > 0 then
        for _, a in ipairs(S.alarms) do
            if y > H - 7 then break end
            local c2 = a.state == "alarm"
                and (a.acked and ui.c.warn or ui.c.alarm) or ui.c.warn
            scr:text(3, y, a.label .. (a.acked and " [ACK]" or ""), c2)
            y = y + 1
        end
    else
        scr:text(3, y, "NO ACTIVE ALARMS", ui.c.okDim)
    end
    local ackC = (S.unacked or 0) > 0 and ui.c.alarm or ui.c.warnDim
    scr:button(2, H - 6, W - 1, H - 4,
        "ACKNOWLEDGE  (" .. (S.unacked or 0) .. " UNACKED)", ackC, "ack", true)
    viewRow(H - 2)
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
            rednet.broadcast({ type = "hello", role = CONFIG.ROLE }, "scada_hello")
        end
        render()
        timer = os.startTimer(0.3)
    elseif event == "rednet_message" and c == "scada_state" then
        if type(b) == "table" and b.type == "state" then
            S = b
            lastSeen = os.clock()
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
