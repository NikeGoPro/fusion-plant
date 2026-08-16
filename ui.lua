--[[
ui.lua -- Fusion Plant SCADA shared UI framework
Custom palette, flicker-free buffered rendering, widget kit, boot sequence.
Used by: bigboard, RPO console, SPO console, master status page.

Usage:
  local ui = require("ui")
  local scr = ui.attach(nil, 0.5)       -- auto-find monitor, scale 0.5
  scr:boot("REACTOR PLANT", "RPO CONSOLE", {"Link master", "Sync state"})
  while true do
    scr:beginFrame()
    scr:panel(2, 2, 30, 10, "PLASMA")
    scr:flush()
    ...
  end
]]

local ui = {}

---------------------------------------------------------------
-- PALETTE (redefines the 16 CC colors into a control-room theme)
---------------------------------------------------------------
local PALETTE = {
    [colors.black]     = 0x060A11, -- background: near-black navy
    [colors.gray]      = 0x18202C, -- panel fill
    [colors.lightGray] = 0x38485C, -- lines, dim text
    [colors.white]     = 0xE8F0F7, -- primary text
    [colors.cyan]      = 0x35C8DE, -- primary accent
    [colors.lightBlue] = 0x8FD2E4, -- steam / dim accent
    [colors.blue]      = 0x2E7DD1, -- water
    [colors.red]       = 0xE23B3B, -- alarm
    [colors.orange]    = 0xF2842B, -- warning
    [colors.yellow]    = 0xF2C230, -- caution
    [colors.lime]      = 0x46D66B, -- OK / running
    [colors.green]     = 0x1F7A46, -- OK dim
    [colors.magenta]   = 0xE04BC0, -- plasma
    [colors.purple]    = 0x7D4BE0, -- plasma dim
    [colors.pink]      = 0xF0A6D8, -- plasma hot
    [colors.brown]     = 0x6E4212, -- dark amber (inactive warn)
}

-- semantic names so pages never hardcode raw colors
ui.c = {
    bg = colors.black,   panel = colors.gray,  line = colors.lightGray,
    text = colors.white, dim = colors.lightGray,
    accent = colors.cyan, accentDim = colors.lightBlue,
    water = colors.blue, steam = colors.lightBlue,
    alarm = colors.red,  warn = colors.orange, caution = colors.yellow,
    ok = colors.lime,    okDim = colors.green,
    plasma = colors.magenta, plasmaDim = colors.purple, plasmaHot = colors.pink,
    warnDim = colors.brown,
}

---------------------------------------------------------------
-- SOUND
-- Local speaker must be DIRECTLY attached (a networked find() could
-- grab a far-away PA speaker). Effects also broadcast to the PA node
-- so they play plant-wide through every PA speaker.
---------------------------------------------------------------
local speaker
for _, side in ipairs({ "top", "bottom", "left", "right", "front", "back" }) do
    if peripheral.getType(side) == "speaker" then
        speaker = peripheral.wrap(side)
        break
    end
end

function ui.sound(name, vol, pitch)
    if speaker then pcall(speaker.playSound, name, vol or 1, pitch or 1) end
    if rednet.isOpen() then
        rednet.broadcast({ type = "sfx", name = name, vol = vol, pitch = pitch },
            "scada_pa")
    end
end

function ui.beep(pitch)
    -- UI clicks stay local-only (no plant-wide click spam)
    if speaker then pcall(speaker.playNote, "bit", 0.4, pitch or 12) end
end

---------------------------------------------------------------
-- BIG DIGIT FONT (3x5 pixels per glyph)
---------------------------------------------------------------
local FONT = {
    ["0"]={"111","101","101","101","111"}, ["1"]={"010","110","010","010","111"},
    ["2"]={"111","001","111","100","111"}, ["3"]={"111","001","111","001","111"},
    ["4"]={"101","101","111","001","001"}, ["5"]={"111","100","111","001","111"},
    ["6"]={"111","100","111","101","111"}, ["7"]={"111","001","010","010","010"},
    ["8"]={"111","101","111","101","111"}, ["9"]={"111","101","111","001","111"},
    ["."]={"0","0","0","0","1"},           ["-"]={"000","000","111","000","000"},
    [" "]={"00","00","00","00","00"},      ["%"]={"101","001","010","100","101"},
    ["K"]={"101","110","100","110","101"}, ["M"]={"101","111","111","101","101"},
    ["G"]={"111","100","101","101","111"}, ["/"]={"001","001","010","100","100"},
    ["t"]={"010","111","010","010","011"},
}

---------------------------------------------------------------
-- SCREEN OBJECT
---------------------------------------------------------------
local Screen = {}
Screen.__index = Screen

function ui.attach(monName, scale)
    local mon, foundName
    if monName then
        mon = peripheral.wrap(monName)
        foundName = monName
        if not mon then error("Monitor not found: " .. monName) end
    else
        mon = peripheral.find("monitor", function(n) foundName = n return true end)
        if not mon then error("No monitor found") end
    end
    if mon.isColor and not mon.isColor() then error("Advanced Monitor required") end

    mon.setTextScale(scale or 0.5)
    for colour, hex in pairs(PALETTE) do
        pcall(mon.setPaletteColour, colour, hex)
    end

    local w, h = mon.getSize()
    local self = setmetatable({}, Screen)
    self.mon, self.name = mon, foundName
    self.w, self.h = w, h
    self.buf = window.create(mon, 1, 1, w, h, false)
    self.touches = {}
    return self
end

function Screen:beginFrame()
    self.touches = {}
    self.buf.setVisible(false)
    self.buf.setBackgroundColor(ui.c.bg)
    self.buf.clear()
end

function Screen:flush()
    self.buf.setVisible(true)
    self.buf.setVisible(false)
end

-- primitives -------------------------------------------------
function Screen:fill(x1, y1, x2, y2, colour)
    x1 = math.max(1, math.floor(x1)); x2 = math.min(self.w, math.floor(x2))
    y1 = math.max(1, math.floor(y1)); y2 = math.min(self.h, math.floor(y2))
    if x2 < x1 or y2 < y1 then return end
    self.buf.setBackgroundColor(colour)
    local row = string.rep(" ", x2 - x1 + 1)
    for y = y1, y2 do
        self.buf.setCursorPos(x1, y)
        self.buf.write(row)
    end
end

function Screen:px(x, y, colour)
    if x >= 1 and x <= self.w and y >= 1 and y <= self.h then
        self.buf.setBackgroundColor(colour)
        self.buf.setCursorPos(x, y)
        self.buf.write(" ")
    end
end

-- fast full-row paint: bgBlit is a string of blit colour chars
-- (build with colors.toBlit). One call paints #bgBlit cells.
function Screen:blitRow(x, y, bgBlit)
    y = math.floor(y)
    if y < 1 or y > self.h then return end
    x = math.floor(x)
    if x < 1 then bgBlit = bgBlit:sub(2 - x); x = 1 end
    local avail = self.w - x + 1
    if #bgBlit > avail then bgBlit = bgBlit:sub(1, avail) end
    if #bgBlit < 1 then return end
    self.buf.setCursorPos(x, y)
    self.buf.blit(string.rep(" ", #bgBlit), bgBlit, bgBlit)
end

function Screen:text(x, y, str, fg, bg)
    x, y = math.floor(x), math.floor(y)
    str = tostring(str)
    if y < 1 or y > self.h or x > self.w then return end
    if x < 1 then str = str:sub(2 - x); x = 1 end
    local avail = self.w - x + 1
    if #str > avail then str = str:sub(1, avail) end
    if #str < 1 then return end
    self.buf.setBackgroundColor(bg or ui.c.bg)
    self.buf.setTextColor(fg or ui.c.text)
    self.buf.setCursorPos(x, y)
    self.buf.write(str)
end

function Screen:center(x1, x2, y, str, fg, bg)
    str = tostring(str)
    local width = x2 - x1 + 1
    if width < 1 then return end
    if #str > width then str = str:sub(1, width) end
    self:text(x1 + math.floor((width - #str) / 2), y, str, fg, bg)
end

-- widgets ----------------------------------------------------
function Screen:panel(x1, y1, x2, y2, title)
    self:fill(x1, y1, x2, y2, ui.c.panel)
    self:fill(x1, y1, x2, y1, ui.c.line)
    if title then
        self:text(x1 + 1, y1, " " .. title .. " ", ui.c.accent, ui.c.line)
    end
end

function Screen:gaugeH(x, y, w, label, frac, readout, colour)
    frac = ui.sane(frac)
    frac = math.max(0, math.min(1, frac or 0))
    self:text(x, y, label, ui.c.dim, ui.c.panel)
    if readout then
        self:text(x + w - #readout, y, readout, ui.c.text, ui.c.panel)
    end
    self:fill(x, y + 1, x + w - 1, y + 1, ui.c.bg)
    local filled = math.floor(w * frac + 0.5)
    if filled > 0 then self:fill(x, y + 1, x + filled - 1, y + 1, colour or ui.c.accent) end
end

-- history: array of numbers; draws last (w) samples
function Screen:spark(x, y, w, h, history, colour, minV, maxV)
    self:fill(x, y, x + w - 1, y + h - 1, ui.c.bg)
    local n = #history
    if n < 2 then return end
    local lo, hi = minV, maxV
    if not lo then
        lo, hi = math.huge, -math.huge
        for _, v in ipairs(history) do
            lo = math.min(lo, v); hi = math.max(hi, v)
        end
    end
    if hi - lo < 1e-9 then hi = lo + 1 end
    for col = 0, w - 1 do
        local idx = n - w + 1 + col
        if idx >= 1 then
            local frac = (history[idx] - lo) / (hi - lo)
            local bars = math.max(1, math.floor(frac * h + 0.5))
            self:fill(x + col, y + h - bars, x + col, y + h - 1, colour or ui.c.accent)
        end
    end
end

function Screen:bigNum(x, y, str, colour)
    local cx = x
    for i = 1, #str do
        local glyph = FONT[str:sub(i, i)]
        if glyph then
            for row = 1, 5 do
                local bits = glyph[row]
                for col = 1, #bits do
                    if bits:sub(col, col) == "1" then
                        self:px(cx + col - 1, y + row - 1, colour or ui.c.text)
                    end
                end
            end
            cx = cx + #glyph[1] + 1
        end
    end
    return cx - x -- rendered width
end

-- state: "ok" | "warn" | "alarm" | "off"; flash: boolean (caller-blinked)
function Screen:tile(x1, y1, x2, y2, label, state, flash)
    local bg = ui.c.panel
    local fg = ui.c.dim
    if state == "ok" then bg, fg = ui.c.okDim, ui.c.text
    elseif state == "warn" then bg, fg = (flash and ui.c.warn or ui.c.warnDim), ui.c.text
    elseif state == "alarm" then bg, fg = (flash and ui.c.alarm or ui.c.panel), ui.c.text end
    self:fill(x1, y1, x2, y2, bg)
    self:center(x1, x2, math.floor((y1 + y2) / 2), label, fg, bg)
end

function Screen:button(x1, y1, x2, y2, label, colour, action, enabled)
    local bg = enabled and colour or ui.c.panel
    local fg = enabled and ui.c.text or ui.c.dim
    self:fill(x1, y1, x2, y2, bg)
    self:center(x1, x2, math.floor((y1 + y2) / 2), label, fg, bg)
    if enabled then
        self.touches[#self.touches + 1] = {x1 = x1, y1 = y1, x2 = x2, y2 = y2, action = action}
    end
end

-- one-row banded level indicator: track with a normal-band segment
-- [lo..hi], and a bright level marker coloured by zone (green in band,
-- amber high, red low). Classic SG level program display.
function Screen:bandBar(x, y, w, frac, lo, hi)
    frac = math.max(0, math.min(1, ui.sane(frac)))
    self:fill(x, y, x + w - 1, y, ui.c.bg)
    local bx1 = x + math.floor(w * (lo or 0.4))
    local bx2 = x + math.max(math.floor(w * (hi or 0.7)) - 1, 0)
    if bx2 >= bx1 then self:fill(bx1, y, bx2, y, ui.c.okDim) end
    local pos = x + math.floor((w - 1) * frac + 0.5)
    local colour = ui.c.ok
    if frac < (lo or 0.4) then colour = ui.c.alarm
    elseif frac > (hi or 0.7) then colour = ui.c.caution end
    self:px(pos, y, colour)
    if pos + 1 <= x + w - 1 then self:px(pos + 1, y, colour) end
end

-- absolute-scale spark: bars scaled 0..maxV with dotted threshold
-- ticks at 85% (warn) and 95% (alarm) so margin-to-limit is visible
function Screen:sparkAbs(x, y, w, h, hist, maxV, colour)
    maxV = math.max(ui.sane(maxV), 1)
    self:fill(x, y, x + w - 1, y + h - 1, ui.c.bg)
    local function tickRow(frac, col)
        local ty = y + h - 1 - math.floor((h - 1) * frac + 0.5)
        for cx = x, x + w - 1, 2 do self:px(cx, ty, col) end
    end
    tickRow(0.85, ui.c.warnDim)
    tickRow(0.95, ui.c.alarm)
    local n = #hist
    for col = 0, w - 1 do
        local idx = n - w + col + 1
        if idx >= 1 then
            local frac = math.max(0, math.min(1, ui.sane(hist[idx]) / maxV))
            local bars = math.floor(h * frac + 0.5)
            if frac > 0 and bars < 1 then bars = 1 end
            if bars > 0 then
                self:fill(x + col, y + h - bars, x + col, y + h - 1, colour)
            end
        end
    end
end

-- LOI (loss of indication): white box where a live value should be.
-- Draw instead of the value when its sensor source is stale.
function Screen:loiBox(x, y, w, label)
    self:fill(x, y, x + w - 1, y, colors.white)
    if label then
        self:text(x + math.floor((w - #label) / 2), y, label,
            ui.c.bg, colors.white)
    end
end

function Screen:hitTest(x, y)
    for i = #self.touches, 1, -1 do
        local t = self.touches[i]
        if x >= t.x1 and x <= t.x2 and y >= t.y1 and y <= t.y2 then
            return t.action
        end
    end
end

---------------------------------------------------------------
-- FORMATTERS
---------------------------------------------------------------
function ui.si(n, unit)
    n = ui.sane(n)
    unit = unit or ""
    local a = math.abs(n)
    if a >= 1e9 then return string.format("%.2fG%s", n / 1e9, unit)
    elseif a >= 1e6 then return string.format("%.2fM%s", n / 1e6, unit)
    elseif a >= 1e3 then return string.format("%.1fK%s", n / 1e3, unit) end
    return string.format("%.0f%s", n, unit)
end

-- real peripherals can return NaN/inf (e.g. 0-capacity tank pct);
-- every display formatter sanitizes its input
function ui.sane(n)
    n = tonumber(n) or 0
    if n ~= n or n == math.huge or n == -math.huge then return 0 end
    return n
end

function ui.pct(frac)
    frac = ui.sane(frac)
    return string.format("%3d%%", math.floor((frac or 0) * 100 + 0.5))
end

---------------------------------------------------------------
-- BOOT SEQUENCE
---------------------------------------------------------------
local LOGO = { -- small atom mark, drawn in plasma colors
    "..1.....1..",
    "1.2.111.2.1",
    ".2.11311.2.",
    "1.2.111.2.1",
    "..1.....1..",
}
local LOGO_C = {[ "1"] = ui.c.plasmaDim, ["2"] = ui.c.plasma, ["3"] = ui.c.text}

function Screen:boot(title, subtitle, steps)
    self:beginFrame()
    local cx = math.floor(self.w / 2)
    local ly = math.floor(self.h / 2) - 8
    for row, line in ipairs(LOGO) do
        for col = 1, #line do
            local ch = line:sub(col, col)
            if LOGO_C[ch] then
                self:px(cx - math.floor(#line / 2) + col - 1, ly + row - 1, LOGO_C[ch])
            end
        end
    end
    self:center(1, self.w, ly + 7, title, ui.c.accent)
    self:center(1, self.w, ly + 8, subtitle, ui.c.dim)
    self:flush()
    ui.sound("block.beacon.power_select", 0.7, 0.7)
    sleep(0.8)

    local sy = ly + 10
    for i, label in ipairs(steps) do
        self:text(cx - 16, sy + i - 1, label .. string.rep(".", 22 - #label), ui.c.dim)
        self:flush()
        ui.beep(6 + i)
        sleep(0.25 + math.random() * 0.3)
        self:text(cx + 8, sy + i - 1, "[ OK ]", ui.c.ok)
        self:flush()
    end
    sleep(0.4)
    ui.sound("block.beacon.activate", 0.8, 1.2)
    self:center(1, self.w, sy + #steps + 1, "SYSTEM READY", ui.c.text)
    self:flush()
    sleep(0.8)
end

return ui
