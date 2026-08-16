--[[
admin.lua -- PLANT ADMIN TERMINAL v3 (five-page, Advanced Pocket)
Pages (bottom tabs, tappable):
  PRI - primary plant: tanks w/ volumes, animated fusion core, fuel
        feed one-line, temp margin bars, two steam pipes exiting the
        right edge at rows 4 and 8, condensate returning at row 16
  SEC - secondary plant: the SAME pipes entering at rows 4/8 (seamless
        pan), MS valves, both MTGs w/ hot wells, matrix, indications
  CTL - plant control: ignite/scram/throttle/gates/M1/battleshort/ack
  SYS - system status: RPS channels, data sources, flags, versions
  ALM - alarms + fleet heartbeat: roster w/ ages+versions, reboot,
        active alarm list, first-out
Requires an ADVANCED pocket computer for tap input (keys still work:
1-5 pages, +/- throttle, k scram, c ack, r/a reboot on ALM page).
]]

local CONFIG = {
    PING_EVERY = 5,
    SCHEDULE = nil, -- e.g. { hour = 4, min = 0, target = "ALL" }
}

local opened = 0
local seen = {}
local candidates = { "back", "front", "top", "bottom", "left", "right" }
for _, name in ipairs(peripheral.getNames()) do
    candidates[#candidates + 1] = name
end
for _, name in ipairs(candidates) do
    if not seen[name] and peripheral.getType(name) == "modem" then
        seen[name] = true
        local ok = pcall(function()
            if not rednet.isOpen(name) then rednet.open(name) end
        end)
        if ok then opened = opened + 1 end
    end
end
if opened == 0 then
    print("No modem found. Side scan:")
    for _, s in ipairs({ "back", "front", "top", "bottom",
        "left", "right" }) do
        print("  " .. s .. ": " .. tostring(peripheral.getType(s)))
    end
    print("On a pocket: put an ender modem in inventory and run")
    print("  lua > pocket.equipBack()")
    error("Admin needs a modem equipped (not just carried)", 0)
end

local W, H = term.getSize()
local S, lastState = nil, -100
local nodes, order = {}, {}
local sel, scroll = 1, 0
local page = "PRI"
local armed, schedFired = nil, nil
local hits, rowAt = {}, {}
local modal = nil   -- { role } node action dialog
local toast = nil   -- { text, til } transient feedback
local tick = 0

-- pipe rows shared by PRI/SEC for the seamless pan
local Y_STEAM1, Y_STEAM2, Y_COND = 4, 8, 16

---------------------------------------------------------------
local function cwrite(x, y, text, fg, bg)
    term.setCursorPos(x, y)
    term.setTextColour(fg or colours.white)
    term.setBackgroundColour(bg or colours.black)
    term.write(text)
end

local function hit(x1, y1, x2, y2, act)
    hits[#hits + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, act = act }
end

local function ping()
    rednet.broadcast({ type = "ping" }, "scada_mgmt")
end

local function cmd(action)
    rednet.broadcast({ type = "cmd", action = action }, "scada_cmd")
end

local function sendReboot(target)
    rednet.broadcast({ type = "reboot", target = target }, "scada_mgmt")
end

local function arm(action, role, label)
    if armed and armed.action == action and armed.role == role
        and os.clock() < armed.til then
        armed = nil
        return true
    end
    armed = { action = action, role = role, til = os.clock() + 3,
        label = label }
    return false
end

local function pct(v) return math.floor((v or 0) * 100 + 0.5) end
local function mB(v)
    v = v or 0
    if v >= 1e9 then return string.format("%.1fG", v / 1e9)
    elseif v >= 1e6 then return string.format("%.1fM", v / 1e6)
    elseif v >= 1e3 then return string.format("%.0fK", v / 1e3) end
    return tostring(math.floor(v))
end

local function hbar(x, y, w, frac, col)
    frac = math.max(0, math.min(1, tonumber(frac) or 0))
    local f = math.floor(w * frac + 0.5)
    term.setCursorPos(x, y)
    term.setBackgroundColour(col)
    term.write(string.rep(" ", f))
    term.setBackgroundColour(colours.grey)
    term.write(string.rep(" ", w - f))
    term.setBackgroundColour(colours.black)
end

-- animated pipe segment (dot marches x1->x2, either direction)
local function pipeH(x1, x2, y, col, flowing)
    local lo, hi = math.min(x1, x2), math.max(x1, x2)
    for x = lo, hi do cwrite(x, y, " ", nil, col) end
    if flowing and hi - lo > 2 then
        local o = tick % (hi - lo + 1)
        local x = (x2 >= x1) and (x1 + o) or (x1 - o)
        cwrite(x, y, " ", nil, colours.white)
    end
end

local function pipeV(x, y1, y2, col, flowing)
    local lo, hi = math.min(y1, y2), math.max(y1, y2)
    for y = lo, hi do cwrite(x, y, " ", nil, col) end
    if flowing and hi - lo > 2 then
        local o = tick % (hi - lo + 1)
        local y = (y2 >= y1) and (y1 + o) or (y1 - o)
        cwrite(x, y, " ", nil, colours.white)
    end
end

---------------------------------------------------------------
local function atomIcon()
    local nx = W - 1
    cwrite(nx, 1, "@", colours.yellow)
    local orbit = { { nx - 1, 1 }, { nx, 2 }, { nx + 1, 1 }, { nx, 2 } }
    local p = orbit[(tick % 4) + 1]
    if p[1] <= W then cwrite(p[1], p[2], "o", colours.cyan) end
end

local function headerBar(title)
    hits = {}
    rowAt = {}
    local ok2 = S and os.clock() - lastState < 3
    cwrite(1, 1, title, colours.cyan)
    if not ok2 then
        cwrite(6, 1, "NO LINK", colours.red)
        atomIcon()
        return nil
    end
    local d = S.data
    local st, sc = "STBY", colours.lightGrey
    if S.igniting then st, sc = "IGNT", colours.orange
    elseif d.ignited then
        st = "MODE" .. (d.injection <= 4 and "1"
            or (d.injection < 98 and "2" or "3"))
        sc = colours.lime
    end
    cwrite(6, 1, st, sc)
    cwrite(12, 1, "I" .. d.injection, colours.white)
    if d.battleshort then cwrite(16, 1, "BS", colours.white, colours.red) end
    if (S.unacked or 0) > 0 then
        cwrite(19, 1, "A" .. math.min(S.unacked, 9), colours.white,
            colours.red)
        hit(19, 1, 21, 1, "ack")
    end
    atomIcon()
    return d
end

local function tabs()
    local names = { "PRI", "SEC", "CTL", "SYS", "ALM" }
    for i, n in ipairs(names) do
        local x = 1 + (i - 1) * 5
        local on = (page == n)
        cwrite(x, H, " " .. n .. " ", on and colours.black or colours.white,
            on and colours.lightGrey or colours.grey)
        hit(x, H, x + 4, H, "page:" .. n)
    end
end

local function confirmBanner(y)
    if armed and os.clock() < armed.til then
        cwrite(1, y, (" CONFIRM " .. armed.label .. " "):sub(1, W),
            colours.white, colours.red)
        return true
    end
    armed = nil
    return false
end

---------------------------------------------------------------
-- PAGE: PRIMARY PLANT
---------------------------------------------------------------
local function renderPRI()
    local d = headerBar("PRI")
    if not d then tabs() return end
    local tk = d.tanks or {}
    local cp = d.tankCaps or {}

    -- core (x14-20, rows 2-10) with animated plasma
    for y = 2, 10 do cwrite(14, y, string.rep(" ", 7), nil, colours.grey) end
    cwrite(15, 2, "CORE", colours.white, colours.grey)
    if d.ignited then
        local pal = { colours.magenta, colours.pink, colours.purple,
            colours.magenta, colours.white }
        for y = 3, 9 do
            for x = 15, 19 do
                local dx, dy = x - 17, (y - 6) * 1.6
                local dd = math.sqrt(dx * dx + dy * dy)
                if dd < 2.8 then
                    local c = dd < 1 and (math.random() < 0.6
                        and colours.white or colours.pink)
                        or pal[math.random(#pal)]
                    cwrite(x, y, " ", nil, c)
                end
            end
        end
    else
        cwrite(15, 6, "COLD", colours.lightGrey, colours.grey)
    end
    cwrite(15, 10, string.format("%3.0fMK", (d.plasmaTemp or 0) / 1e6),
        colours.white, colours.grey)

    -- two steam pipes exiting the right edge (seamless to SEC page)
    local flowing = (d.steamFlow or 0) > 100
    pipeH(21, W, Y_STEAM1, colours.lightBlue, flowing)
    pipeH(21, W, Y_STEAM2, colours.lightBlue, flowing)
    -- condensate returning from the right edge into the core base
    pipeH(W, 21, Y_COND, colours.blue, flowing)
    pipeV(21, Y_COND - 1, 11, colours.blue, flowing)

    -- fuel feed riser: tank column -> core
    local fueling = d.ignited and d.injection > 0
    pipeV(13, 9, 3, colours.green, fueling)

    -- tanks with volumes (left column, rows 2-6 name/pct/vol; bar row 7-11? no: one row each rows 2-11 alt)
    local tanks = {
        { "LI", tk.li, cp.li, colours.purple },
        { "HW", tk.hw, cp.hw, colours.lightBlue },
        { "WS", tk.stor, cp.stor, colours.blue },
        { "DE", d.deut, cp.deut, colours.cyan },
        { "TR", d.trit, cp.trit, colours.lime },
    }
    for i, t in ipairs(tanks) do
        local y = 1 + i * 2
        cwrite(1, y, t[1], colours.lightGrey)
        cwrite(4, y, pct(t[2]) .. "%", colours.white)
        cwrite(8, y, t[3] and mB((t[2] or 0) * t[3]) or "", t[4])
        hbar(1, y + 1, 11, t[2] or 0, t[4])
    end

    -- feed + reactor inventory line
    cwrite(1, 16, d.dtBurn and ("FD " .. math.floor(d.dtBurn) .. "mB/t")
        or ("FD " .. (d.injection / 2) .. "+" .. (d.injection / 2)),
        colours.green)
    cwrite(13, 12, "RW" .. pct(d.water) .. " S" .. pct(d.steam),
        colours.blue)

    -- temperature margin bars vs limits (85/95 coloring)
    local function marginRow(y, label, v, maxV)
        local frac = (v or 0) / math.max(maxV or 1, 1)
        cwrite(1, y, label, colours.cyan)
        hbar(5, y, 12, frac, frac >= 0.95 and colours.red
            or (frac >= 0.85 and colours.orange or colours.green))
        cwrite(18, y, pct(frac) .. "%", frac >= 0.95 and colours.red
            or (frac >= 0.85 and colours.orange or colours.white))
    end
    marginRow(13, "PLT", d.plasmaTemp, d.maxPlasma)
    marginRow(14, "CST", d.caseTemp, d.maxCase)

    local burn = d.injection / 2
    cwrite(1, 15, ("PROD D%+.1f T%+.1f"):format(
        (d.prodD or 0) - burn, (d.prodT or 0) - burn),
        ((d.prodD or 0) < burn or (d.prodT or 0) < burn)
        and colours.red or colours.lime)
    cwrite(1, 17, "STEAM->", colours.lightBlue)
    cwrite(1, 18, (d.runback and "RUNBACK " or "")
        .. (d.rxLive and "RX:LIVE" or "RX:SIM"),
        d.runback and colours.orange or colours.lightGrey)
    confirmBanner(19)
    tabs()
end

---------------------------------------------------------------
-- PAGE: SECONDARY PLANT
---------------------------------------------------------------
local function renderSEC()
    local d = headerBar("SEC")
    if not d then tabs() return end
    local flowing = (d.steamFlow or 0) > 100

    -- condensate header exiting left at the same row (drawn first;
    -- steam inlets repaint their crossing so steam passes in front)
    pipeH(11, 1, Y_COND, colours.blue, flowing)

    for ti, ty in ipairs({ Y_STEAM1, Y_STEAM2 }) do
        local t = (d.turbines or {})[ti] or {}
        local open = t.online
        -- steam inlet: seamless from PRI, runs through to the block edge
        -- (drawn per-unit so it repaints the shared downcomer crossing)
        pipeH(1, 7, ty, colours.lightBlue, flowing)
        -- MS valve on the pipe
        cwrite(5, ty, open and "><" or "><", open and colours.lime
            or colours.red, colours.black)
        cwrite(3, ty - 1, "MS" .. ti, colours.lightGrey)
        -- MTG block
        local sc2 = colours.grey
        if not t.online then sc2 = colours.red
        elseif d.ignited and (t.flow or 0) > 100 then sc2 = colours.green
        elseif d.ignited then sc2 = colours.orange end
        for y = ty - 1, ty + 1 do
            cwrite(8, y, string.rep(" ", 10), nil, sc2)
        end
        cwrite(9, ty - 1, "MTG" .. ti .. (t.live and " LIV" or " sim"),
            colours.white, sc2)
        cwrite(9, ty, ("F%4.1fM"):format((t.flow or 0) / 1e6),
            colours.black, sc2)
        cwrite(9, ty + 1, ("P%4.1fM"):format((t.prod or 0) / 1e6),
            colours.black, sc2)
        -- hot well + CS drop to the condensate header
        local hw = t.water
        cwrite(8, ty + 2, "HW", colours.lightGrey)
        if hw then
            hbar(11, ty + 2, 5, hw, (hw >= 0.4 and hw <= 0.7)
                and colours.lime or colours.red)
            cwrite(17, ty + 2, pct(hw), colours.white)
        else
            cwrite(11, ty + 2, "NOINST", colours.grey)
        end
        pipeV(7, ty + 1, Y_COND, colours.blue, flowing and open)
        -- generator lead to matrix bus
        pipeH(18, 20, ty, colours.yellow, d.ignited)
    end

    -- matrix (right column)
    local m = d.matrix or {}
    local mc = m.energy or 0
    for y = 3, 12 do cwrite(21, y, string.rep(" ", 6), nil, colours.grey) end
    cwrite(21, 3, "MATRIX", colours.white, colours.grey)
    cwrite(21, 4, pct(mc) .. "%", mc > 0.9 and colours.red or colours.yellow,
        colours.grey)
    -- vertical charge bar
    local bh = 7
    local f = math.floor(bh * math.min(mc, 1) + 0.5)
    for i = 0, bh - 1 do
        local col = (i < f) and (mc > 0.97 and colours.red
            or (mc > 0.9 and colours.orange or colours.yellow))
            or colours.black
        cwrite(23, 12 - i, "  ", nil, col)
    end
    cwrite(21, 13, "I" .. math.floor((m.input or 0) / 1e6) .. "M",
        colours.lime)
    cwrite(21, 14, "O" .. math.floor((m.output or 0) / 1e6) .. "M",
        colours.orange)

    -- indications strip
    local nOn = 0
    for _, t in ipairs(d.turbines or {}) do
        if t.online then nOn = nOn + 1 end
    end
    cwrite(9, 13, ("S%.1f/%.1fM"):format((d.steamFlow or 0) / 1e6,
        d.injection * 150000 / 1e6), colours.lightBlue)
    cwrite(9, 14, "P" .. math.min(98, nOn * 78)
        .. (d.runback and " RUNBK" or ""),
        d.runback and colours.orange or colours.white)
    cwrite(1, 17, "<-CONDENSATE", colours.blue)
    cwrite(1, 18, (d.mtxLive and "MTX:LIVE " or "MTX:SIM ")
        .. (d.tanksLive and "TK:LIVE" or "TK:SIM"), colours.lightGrey)
    confirmBanner(19)
    tabs()
end

---------------------------------------------------------------
-- PAGE: PLANT CONTROL
---------------------------------------------------------------
local function renderCTL()
    local d = headerBar("CTL")
    if not d then tabs() return end
    local V = d.valves or {}
    local function vs(v)
        if not v or not v.pos then return "?" end
        if v.pos > 99 then return "OPEN"
        elseif v.pos < 1 then return "SHUT" end
        return math.floor(v.pos) .. "%"
    end
    cwrite(1, 2, "FVD " .. vs(V.fvd) .. " FVT " .. vs(V.fvt),
        colours.white)
    cwrite(1, 3, "FCV " .. vs(V.fcv) .. "  INJ " .. d.injection .. "mB/t",
        colours.cyan)
    local function big(x1, y1, x2, y2, label, act, bg, fg, en)
        if en == false then bg = colours.grey fg = colours.lightGrey end
        for y = y1, y2 do
            cwrite(x1, y, string.rep(" ", x2 - x1 + 1), nil, bg)
        end
        cwrite(x1 + math.floor((x2 - x1 + 1 - #label) / 2),
            math.floor((y1 + y2) / 2), label, fg or colours.white, bg)
        if en ~= false then hit(x1, y1, x2, y2, act) end
    end
    big(1, 5, 12, 7, "IGNITE", "ignite", colours.green, colours.black,
        not d.ignited and not S.igniting)
    big(14, 5, 26, 7, "SCRAM", "scram", colours.red)
    big(1, 9, 12, 10, "THR -", "thrDown", colours.grey)
    big(14, 9, 26, 10, "THR +", "thrUp", colours.green, colours.black)
    big(1, 12, 8, 13, "FV-D", "fvd", colours.brown)
    big(10, 12, 17, 13, "FV-T", "fvt", colours.brown)
    big(19, 12, 26, 13, "M1", "mode1", colours.cyan, colours.black)
    big(1, 15, 12, 16, d.battleshort and "BSHORT ON" or "BSHORT",
        "battleshort", d.battleshort and colours.red or colours.grey)
    big(14, 15, 26, 16, "ACK " .. (S.unacked or 0), "ack",
        (S.unacked or 0) > 0 and colours.orange or colours.grey,
        colours.black)
    cwrite(1, 18, (d.runback and "RUNBACK ACTIVE " or "")
        .. (S.firstOut and ("FO:" .. S.firstOut):sub(1, 26) or ""),
        colours.orange)
    confirmBanner(19)
    tabs()
end

---------------------------------------------------------------
-- PAGE: SYSTEM STATUS
---------------------------------------------------------------
local function renderSYS()
    local d = headerBar("SYS")
    if not d then tabs() return end
    local st = {}
    for _, a in ipairs(S.alarms or {}) do st[a.id] = a.state end
    local tripped = st.SCRAM or st.FLAMEOUT
    cwrite(1, 2, "RPS " .. (tripped and "TRIPPED" or "NORMAL"),
        tripped and colours.red or colours.lime)
    local inv = S.chInvalid or {}
    local ch = {
        { "RT1 FUEL", st.DT_LO or st.TPROD, nil },
        { "RT2 RXWTR", st.WTR_LO, inv.water },
        { "RT3 STEAM", st.STM_HI, inv.steam },
        { "RT4 HTSNK", st.TB_TRIP or st.FLOW_LO or st.MTX_HI, nil },
        { "RT5 CASE", st.CST_HI, inv.case },
        { "RT6 SGLVL", st.SG_LVL, nil },
    }
    for i, c in ipairs(ch) do
        local y = 2 + i
        cwrite(1, y, c[1], colours.lightGrey)
        local s2, col = "OK", colours.lime
        if c[3] then s2, col = "INVALID", colours.white
        elseif d.rxStale and (i == 2 or i == 3 or i == 5) then
            s2, col = "INOP", colours.grey
        elseif c[2] == "alarm" then s2, col = "TRIP", colours.red
        elseif c[2] == "warn" then s2, col = "PRETRIP", colours.orange end
        cwrite(13, y, s2, col)
    end
    cwrite(1, 10, "SOURCES", colours.cyan)
    cwrite(1, 11, "RX " .. (d.rxLive and "LIVE" or "SIM"),
        d.rxLive and colours.lime or colours.grey)
    cwrite(9, 11, "TK " .. (d.tanksLive and "LIVE" or "SIM"),
        d.tanksLive and colours.lime or colours.grey)
    cwrite(17, 11, "MX " .. (d.mtxLive and "LIVE" or "SIM"),
        d.mtxLive and colours.lime or colours.grey)
    local nLoi = 0
    for _ in pairs(S.loi or {}) do nLoi = nLoi + 1 end
    cwrite(1, 13, "LOI " .. nLoi, nLoi > 0 and colours.red or colours.lime)
    cwrite(8, 13, "BS " .. (d.battleshort and "ON" or "off"),
        d.battleshort and colours.red or colours.grey)
    cwrite(16, 13, "RB " .. (d.runback and "ON" or "off"),
        d.runback and colours.orange or colours.grey)
    cwrite(1, 15, "MODE " .. (d.modeText or "?"):sub(1, 21), colours.white)
    -- fleet version consensus
    local vers = {}
    for _, n in pairs(nodes) do
        local v = tostring(n.version or "?")
        vers[v] = (vers[v] or 0) + 1
    end
    local vs2 = {}
    for v, c in pairs(vers) do vs2[#vs2 + 1] = "v" .. v .. "x" .. c end
    table.sort(vs2)
    cwrite(1, 17, "FLEET " .. table.concat(vs2, " "):sub(1, 20),
        #vs2 <= 1 and colours.lime or colours.orange)
    confirmBanner(19)
    tabs()
end

---------------------------------------------------------------
-- PAGE: ALARMS + FLEET HEARTBEAT
---------------------------------------------------------------
local function renderALM()
    local d = headerBar("ALM")
    tabs()
    order = {}
    for role in pairs(nodes) do order[#order + 1] = role end
    table.sort(order)
    if sel > #order then sel = math.max(1, #order) end
    local top = 2
    local visible = 9
    if sel <= scroll then scroll = sel - 1 end
    if sel > scroll + visible then scroll = sel - visible end
    scroll = math.max(0, math.min(scroll, math.max(0, #order - visible)))
    for i = 1, math.min(#order - scroll, visible) do
        local idx = i + scroll
        local role = order[idx]
        local n = nodes[role]
        local age = math.floor(os.clock() - n.t)
        local up = age < 12
        local y = top + i - 1
        rowAt[y] = idx
        local bg = idx == sel and colours.grey or colours.black
        if idx == sel then
            cwrite(1, y, string.rep(" ", W), nil, bg)
        end
        cwrite(1, y, role:sub(1, 13), up and colours.white or colours.red, bg)
        cwrite(16, y, up and (age .. "s") or "LOST",
            up and colours.lightGrey or colours.red, bg)
        cwrite(22, y, "v" .. tostring(n.version or "?"), colours.cyan, bg)
    end
    if #order == 0 then cwrite(1, top, "discovering...", colours.lightGrey) end
    cwrite(1, 11, "-" and string.rep("-", W), colours.grey)
    if S and S.alarms and #S.alarms > 0 then
        for i = 1, math.min(#S.alarms, 5) do
            local a = S.alarms[i]
            cwrite(1, 11 + i, a.label:sub(1, 22)
                .. (a.acked and " A" or ""),
                a.state == "alarm" and colours.red or colours.orange)
        end
    else
        cwrite(1, 12, "NO ACTIVE ALARMS", colours.lime)
    end
    if S and S.firstOut then
        cwrite(1, 17, ("FO:" .. S.firstOut):sub(1, W), colours.red)
    end
    cwrite(1, 18, " RBT ", colours.black, colours.orange)
    hit(1, 18, 5, 18, "reboot")
    cwrite(7, 18, " ALL ", colours.white, colours.red)
    hit(7, 18, 11, 18, "rebootall")
    cwrite(13, 18, " PING ", colours.white, colours.grey)
    hit(13, 18, 18, 18, "ping")
    cwrite(20, 18, " ACK ", colours.white, colours.brown)
    hit(20, 18, 24, 18, "ack")
    confirmBanner(19)
end

---------------------------------------------------------------
local function drawModal()
    if not modal then return end
    hits = {}
    rowAt = {}
    local n = nodes[modal.role] or {}
    local up = n.t and (os.clock() - n.t < 12)
    for y = 7, 14 do
        cwrite(2, y, string.rep(" ", W - 2), nil, colours.grey)
    end
    cwrite(2, 7, string.rep(" ", W - 2), nil, colours.lightGrey)
    cwrite(4, 7, " NODE ACTION ", colours.black, colours.lightGrey)
    cwrite(4, 9, modal.role:sub(1, W - 6), colours.white, colours.grey)
    cwrite(4, 10, (up and ("LINK OK  " .. math.floor(os.clock() - n.t) .. "s")
        or "LINK LOST"), up and colours.lime or colours.red, colours.grey)
    cwrite(4, 11, "version v" .. tostring(n.version or "?"),
        colours.cyan, colours.grey)
    cwrite(4, 13, " REBOOT ", colours.white, colours.red)
    hit(4, 13, 11, 13, "modal:reboot")
    cwrite(14, 13, " CANCEL ", colours.black, colours.lightGrey)
    hit(14, 13, 21, 13, "modal:cancel")
end

local function drawToast()
    if toast and os.clock() < toast.til then
        cwrite(1, 19, (" " .. toast.text .. " "):sub(1, W),
            colours.black, colours.lime)
    elseif toast then
        toast = nil
    end
end

local function render()
    term.setBackgroundColour(colours.black)
    term.clear()
    if page == "PRI" then renderPRI()
    elseif page == "SEC" then renderSEC()
    elseif page == "CTL" then renderCTL()
    elseif page == "SYS" then renderSYS()
    else renderALM() end
    drawModal()
    drawToast()
end

local function doAction(act)
    if act == "modal:reboot" then
        if modal then
            sendReboot(modal.role)
            toast = { text = "REBOOT SENT -> " .. modal.role,
                til = os.clock() + 2.5 }
            modal = nil
        end
    elseif act == "modal:cancel" then
        modal = nil
    elseif act:sub(1, 5) == "page:" then
        page = act:sub(6)
    elseif act == "reboot" and order[sel] then
        if arm("reboot", order[sel], "REBOOT " .. order[sel]) then
            sendReboot(order[sel])
        end
    elseif act == "rebootall" then
        if arm("rebootall", "*", "REBOOT ALL") then sendReboot("ALL") end
    elseif act == "scram" then
        if arm("scram", "*", "SCRAM") then cmd("scram") end
    elseif act == "ignite" then
        if arm("ignite", "*", "IGNITION SEQUENCE") then cmd("ignite") end
    elseif act == "battleshort" then
        if arm("bs", "*", "BATTLESHORT TOGGLE") then cmd("battleshort") end
    elseif act == "ack" then cmd("ack")
    elseif act == "thrUp" then cmd("fcvUp")
    elseif act == "thrDown" then cmd("fcvDown")
    elseif act == "fvd" then cmd("fvd")
    elseif act == "fvt" then cmd("fvt")
    elseif act == "mode1" then cmd("mode1")
    elseif act == "ping" then ping()
    end
end

---------------------------------------------------------------
print("Admin v3 online (" .. opened .. " modem(s)).")
ping()
local timer = os.startTimer(0.3)

while true do
    local event, a, b, c = os.pullEvent()
    if event == "timer" and a == timer then
        tick = tick + 1
        if tick % (CONFIG.PING_EVERY * 3) == 1 then ping() end
        if CONFIG.SCHEDULE then
            local t = os.date("*t")
            local stamp = t.year .. "-" .. t.yday
            if t.hour == CONFIG.SCHEDULE.hour
                and t.min == CONFIG.SCHEDULE.min and schedFired ~= stamp then
                schedFired = stamp
                sendReboot(CONFIG.SCHEDULE.target or "ALL")
            end
        end
        render()
        timer = os.startTimer(0.3)
    elseif event == "rednet_message" and c == "scada_mgmt" then
        if type(b) == "table" and b.type == "pong" and b.role then
            nodes[b.role] = { t = os.clock(), version = b.version }
        end
    elseif event == "rednet_message" and c == "scada_state" then
        if type(b) == "table" and b.type == "state" then
            S = b
            lastState = os.clock()
            nodes["MASTER"] = nodes["MASTER"] or { t = 0, version = "?" }
            nodes["MASTER"].t = os.clock()
        end
    elseif event == "mouse_click" then
        local mx, my = b, c
        if page == "ALM" and rowAt[my] and not modal then
            sel = rowAt[my]
            modal = { role = order[sel] }
        else
            for _, h in ipairs(hits) do
                if mx >= h.x1 and mx <= h.x2 and my >= h.y1
                    and my <= h.y2 then
                    doAction(h.act)
                    break
                end
            end
        end
        render()
    elseif event == "mouse_scroll" and page == "ALM" then
        sel = math.max(1, math.min(#order, sel + b))
        render()
    elseif event == "key" then
        if modal then
            if a == keys.enter or a == keys.r then
                doAction("modal:reboot")
            else
                modal = nil
            end
            render()
        elseif page == "ALM" then
            if a == keys.up then sel = math.max(1, sel - 1)
            elseif a == keys.down then sel = math.min(#order, sel + 1) end
        end
        render()
    elseif event == "char" then
        local ch = a:lower()
        local pages = { ["1"] = "PRI", ["2"] = "SEC", ["3"] = "CTL",
            ["4"] = "SYS", ["5"] = "ALM" }
        if pages[ch] then page = pages[ch]
        elseif ch == "+" or ch == "=" then doAction("thrUp")
        elseif ch == "-" then doAction("thrDown")
        elseif ch == "k" then doAction("scram")
        elseif ch == "c" then doAction("ack")
        elseif ch == "r" and page == "ALM" then doAction("reboot")
        elseif ch == "a" and page == "ALM" then doAction("rebootall")
        end
        render()
    end
end
