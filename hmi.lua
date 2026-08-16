--[[
hmi.lua -- Fusion Plant Multi-Page HMI console (replaces coreboard.lua)
Requires ui.lua (with blitRow) on the same computer.

Pages (touch tabs in header):
  CORE    - chamber cross-section, plasma orb, 4 trend graphs
  PARAMS  - dense reactor plant parameters grid w/ limits + trend arrows
  STEAM   - 6-turbine table, totals, induction matrix
  ALARMS  - latched annunciator tiles + time-stamped alarm history

Master control strip on every page: IGNITE/SCRAM, ACK ALL, INJ -/+.
SIM = true. readData() is the only function replaced for real data.
]]

local ui = require("ui")
local CONFIG = { SIM = true, scale = 0.5 }
local scr = ui.attach(nil, CONFIG.scale)

---------------------------------------------------------------
-- PA SYSTEM LINK (broadcasts to pa.lua audio node, if reachable)
---------------------------------------------------------------
local PA_PROTO = "scada_pa"
local paReady = false
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
        if not rednet.isOpen(name) then rednet.open(name) end
        paReady = true
    end
end

local function pa(name, interrupt)
    if paReady then
        rednet.broadcast({ type = "play", name = name,
            interrupt = interrupt or false }, PA_PROTO)
    end
end

-- name = dfpwm file to loop as plant ambience, nil = stop the loop
local function paAmbient(name)
    if paReady then
        rednet.broadcast({ type = "ambient", name = name }, PA_PROTO)
    end
end

---------------------------------------------------------------
-- PLANT STATE
---------------------------------------------------------------
local DATA = {
    ignited = false, plasmaTemp = 300, caseTemp = 300,
    production = 0, passiveGen = 0, steamFlow = 0,
    envLoss = 0, transferLoss = 0,
    water = 0.94, steam = 0.06, deut = 0.81, trit = 0.67, dtfuel = 0.42,
    injection = 98, hohlraum = true,
    battleshort = false, -- protection bypass: annunciate, don't actuate
    -- fuel train: bulk tanks + production rates vs burn
    tanks = { li = 0.58, hw = 0.72, stor = 0.94 }, -- liq lithium, heavy water, water storage
    -- nominal capacities (mB) for volume readouts; replaced by real
    -- telemetry once tanks are bound. Deuterium measured at 4B.
    tankCaps = { li = 4e9, hw = 4e9, stor = 4e9, deut = 4e9, trit = 4e9 },
    prodD = 0, prodT = 0, -- separator / SNA output, mB/t
    lasers = {0.98, 0.97, 1.0, 0.99},
    -- design/theoretical, water-cooled (real mode: getMaxPlasmaTemperature(true))
    maxPlasma = 150e6, maxCase = 50e6, ignitionTemp = 1.0e8,
    turbines = {}, matrix = { energy = 0.35, input = 0, output = 0 },
    -- virtual fuel valves: FV-D/FV-T gates + FCV-1 throttle (percent).
    -- pos strokes toward demand each scan; injection derives from these.
    valves = {
        fvd = { pos = 0, demand = 0 },
        fvt = { pos = 0, demand = 0 },
        fcv = { pos = 0, demand = 0 },
    },
}
-- valve lineup survives reboots (no phantom shut valves on restart)
if fs.exists("valve_state") then
    local f = fs.open("valve_state", "r")
    local vs = textutils.unserialize(f.readAll())
    f.close()
    if type(vs) == "table" then
        for k, v in pairs(vs) do
            if DATA.valves[k] then
                DATA.valves[k].demand = v
                DATA.valves[k].pos = v
            end
        end
    end
end
local function saveValves()
    local f = fs.open("valve_state", "w")
    f.write(textutils.serialize({
        fvd = DATA.valves.fvd.demand,
        fvt = DATA.valves.fvt.demand,
        fcv = DATA.valves.fcv.demand,
    }))
    f.close()
end

for i = 1, 2 do
    DATA.turbines[i] = { flow = 0, prod = 0, steamPct = 0.05,
                         buffer = 0.2, water = 0.55, mode = "IDLE", online = true }
end

local hist = { plasma = {}, case = {}, prod = {}, flow = {} }
local telemetry = {}  -- node name -> { t, turbine, tank, readings }
local TELEM_FRESH = 5 -- seconds (ride through server lag without flapping LIVE)
local lastSentInj = nil    -- last injection demand pushed to the reactor
local tripLatched = false  -- RPS protective action one-shot
local prevRed = false
local tankPrev = {}        -- D/T level history for computed production
local rxWasIgnited = false -- rising-edge detect for already-burning reactor
local prev = {}          -- for trend arrows
local tick, flash = 0, false
local page = "CORE"
local igniting = false
local seqStage, seqInfo = nil, nil   -- broadcast so walls can follow the show

local function push(t, v)
    t[#t + 1] = v
    if #t > 300 then table.remove(t, 1) end
end
local function approach(c, t, r) return c + (t - c) * r end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

-- trend arrow vs last tick: rising / falling / steady
local function arrow(key, v)
    local p = prev[key]
    prev[key] = v
    if not p then return " ", ui.c.dim end
    local d = v - p
    local mag = math.max(math.abs(v), 1) * 0.0005
    if d > mag then return "^", ui.c.caution
    elseif d < -mag then return "v", ui.c.accentDim end
    return "-", ui.c.dim
end

---------------------------------------------------------------
-- ALARM ENGINE (latched, acknowledgeable, logged)
---------------------------------------------------------------
local loiList = {}  -- role -> true while a known node's link is lost
local scramAt = nil -- when a SCRAM was commanded (for fail-to-scram watch)

local ALARM_DEFS = {
    {id = "PLT_HI",  label = "PLASMA TEMP HI",  sustain = 1, f = function(d)
        if d.rxStale then return nil end
        if d.plasmaTemp > 0.95 * d.maxPlasma then return "alarm"
        elseif d.plasmaTemp > 0.85 * d.maxPlasma then return "warn" end end},
    {id = "CST_HI",  label = "CASE TEMP HI",    sustain = 1, f = function(d)
        if d.rxStale or chInvalid.case then return nil end
        if d.caseTemp > 0.95 * d.maxCase then return "alarm"
        elseif d.caseTemp > 0.85 * d.maxCase then return "warn" end end},
    {id = "WTR_LO",  label = "RX WATER LVL LO", sustain = 2, f = function(d)
        if d.rxStale or chInvalid.water then return nil end
        if d.water < 0.15 then return "alarm"
        elseif d.water < 0.30 then return "warn" end end},
    {id = "STM_HI",  label = "RX STEAM PRESS HI", sustain = 2, f = function(d)
        if d.rxStale or chInvalid.steam then return nil end
        if d.steam > 0.92 then return "alarm"
        elseif d.steam > 0.80 then return "warn" end end},
    {id = "DT_LO",   label = "D-T FUEL LO",     f = function(d)
        if d.ignited and d.dtfuel < 0.15 then return "alarm"
        elseif d.ignited and d.dtfuel < 0.30 then return "warn" end end},
    {id = "D_LO",    label = "DEUTERIUM LO",    f = function(d)
        if d.deut < 0.15 then return "warn" end end},
    {id = "T_LO",    label = "TRITIUM LO",      f = function(d)
        if d.trit < 0.15 then return "warn" end end},
    {id = "TB_TRIP", label = "TURBINE TRIP",    sustain = 10, f = function(d)
        if not d.ignited then return end
        for _, t in ipairs(d.turbines) do
            if t.online and t.flow < 100 then return "alarm" end
        end end},
    {id = "FLOW_LO", label = "STEAM FLOW LO",   sustain = 10, f = function(d)
        if d.ignited and d.steamFlow < 7.0e6 then return "warn" end end},
    {id = "LSR_LO",  label = "LASER BANK LO",   f = function(d)
        for _, l in ipairs(d.lasers) do
            if l < 0.5 and not d.ignited then return "warn" end
        end end},
    {id = "SG_LVL", label = "SG LEVEL LO",     sustain = 5, f = function(d)
        local worst
        for _, t in ipairs(d.turbines) do
            if t.online and t.water then
                if t.water < 0.12 then return "alarm"
                elseif t.water < 0.25 then worst = "warn" end
            end
        end
        return worst end},
    {id = "CH_INV", label = "RPI CH INVALID", f = function()
        for _ in pairs(chInvalid) do return "warn" end end},
    {id = "LOI", label = "LOSS OF INDICATION", f = function()
        for _ in pairs(loiList) do return "warn" end end},
    {id = "MTX_HI", label = "IND MATRIX HI",   sustain = 3, f = function(d)
        local e = d.matrix and d.matrix.energy or 0
        if e > 0.97 then return "alarm" elseif e > 0.90 then return "warn" end end},
    {id = "TPROD", label = "T PROD MARGIN LO", sustain = 10, f = function(d)
        if d.ignited and (d.prodT or 99) < d.injection / 2 then return "warn" end end},
    {id = "ATWS",   label = "FAIL TO SCRAM",    f = function(d)
        if scramAt and os.clock() - scramAt > 10 and d.ignited then
            return "alarm"
        end end},
    {id = "SCRAM",   label = "REACTOR SCRAM",   f = function() end}, -- event-latched
    {id = "FLAMEOUT", label = "RX FLAMEOUT",    f = function() end}, -- event-latched
}

local alarmState = {}   -- id -> {state="warn"/"alarm", acked=bool}
local alarmPend = {}    -- id -> os.clock when condition first seen (sustain)
local chInvalid = {}    -- param -> true when reading failed plausibility
local alarmLog = {}     -- {time, text, colour}
local firstOut = nil    -- first red alarm since last acknowledge (RPS first-out)

local function logEvent(text, colour)
    table.insert(alarmLog, 1, { time = os.date("%H:%M:%S"), text = text, colour = colour })
    if #alarmLog > 40 then table.remove(alarmLog) end
end

local function raiseAlarm(id, label, state)
    alarmState[id] = { state = state, acked = false }
    if state == "alarm" and not firstOut then firstOut = label end
    logEvent(label .. " [" .. state:upper() .. "]",
        state == "alarm" and ui.c.alarm or ui.c.warn)
    ui.sound(state == "alarm" and "block.note_block.bell" or "block.note_block.bit",
        1, state == "alarm" and 0.6 or 1.2)
end

local PROTECTIVE = { PLT_HI = true, CST_HI = true, WTR_LO = true,
    STM_HI = true, TB_TRIP = true, MTX_HI = true }

local function rpsAction()
    local red = false
    for id in pairs(PROTECTIVE) do
        local a = alarmState[id]
        if a and a.state == "alarm" then red = true break end
    end
    if red and not prevRed then
        if igniting then
            logEvent("RPS STARTUP BYPASS - ACTION INHIBITED", ui.c.caution)
        elseif DATA.battleshort then
            logEvent("RPS TRIP BLOCKED - BATTLESHORT", ui.c.warn)
        elseif DATA.ignited and not tripLatched then
            tripLatched = true
            DATA.valves.fcv.demand = 0
            saveValves()
            logEvent("RPS TRIP - FCV CLOSING"
                .. (firstOut and (" (" .. firstOut .. ")") or ""), ui.c.alarm)
            pa("scram_voice")
        end
    end
    if not red then tripLatched = false end
    prevRed = red
end

local function evalAlarms()
    local now = os.clock()
    for _, def in ipairs(ALARM_DEFS) do
        local state = def.f(DATA)
        if state then
            alarmPend[def.id] = alarmPend[def.id] or now
            if now - alarmPend[def.id] >= (def.sustain or 0) then
                local a = alarmState[def.id]
                if not a or a.state ~= state then
                    raiseAlarm(def.id, def.label, state)
                    logEvent(def.label .. " [" .. state:upper() .. "]",
                        state == "alarm" and ui.c.alarm or ui.c.warn)
                    if state == "alarm" then
                        ui.sound("block.note_block.pling", 1, 0.5)
                    end
                end
            end
        else
            alarmPend[def.id] = nil
            if alarmState[def.id] and def.id ~= "SCRAM"
                and def.id ~= "FLAMEOUT" then
                alarmState[def.id] = nil
                logEvent(def.label .. " CLEARED", ui.c.okDim)
            end
        end
    end
end

local function unackedCount()
    local n = 0
    for _, a in pairs(alarmState) do
        if not a.acked then n = n + 1 end
    end
    return n
end

local function ackAll()
    for _, a in pairs(alarmState) do a.acked = true end
    alarmState["SCRAM"] = nil    -- event latches clear on acknowledge
    alarmState["FLAMEOUT"] = nil
    firstOut = nil
    ui.beep(4)
    logEvent("ALARMS ACKNOWLEDGED", ui.c.dim)
end

---------------------------------------------------------------
-- SIMULATION / DATA SOURCE
---------------------------------------------------------------
---------------------------------------------------------------
-- VIRTUAL FUEL VALVES (gates stroke ~4s, throttle ramps ~7s)
---------------------------------------------------------------
local GATE_STROKE = 5  -- % per 0.2s scan
local FCV_STROKE  = 3

local function valveTick()
    local V = DATA.valves
    for name, v in pairs(V) do
        local rate = (name == "fcv") and FCV_STROKE or GATE_STROKE
        if v.pos < v.demand then v.pos = math.min(v.demand, v.pos + rate)
        elseif v.pos > v.demand then v.pos = math.max(v.demand, v.pos - rate) end
    end
    local gatesOpen = V.fvd.pos > 99 and V.fvt.pos > 99
    local inj = 0
    if gatesOpen then
        inj = math.floor(V.fcv.pos / 100 * 49 + 0.5) * 2
        if DATA.ignited and inj < 2 then inj = 2 end -- FCV low-limit stop
    end
    -- AUTOMATIC RUNBACK: allowable injection follows online turbine
    -- capacity (78 mB/t of injection per max MTG). Isolating a turbine
    -- at the SPCP throttles the reactor to what the lineup can carry.
    local nOn = 0
    for _, t in ipairs(DATA.turbines) do
        if t.online then nOn = nOn + 1 end
    end
    local permInj = math.min(98, math.floor(nOn * 78 / 2) * 2)
    if DATA.battleshort then permInj = 98 end
    if inj > permInj then
        if not DATA.runback then
            logEvent("AUTO RUNBACK - PERM INJ " .. permInj .. " mB/t",
                ui.c.warn)
        end
        DATA.runback = true
        inj = permInj
    elseif DATA.runback then
        DATA.runback = false
        logEvent("RUNBACK CLEARED", ui.c.okDim)
    end
    if DATA.ignited and inj == 0 and DATA.injection > 0 and not DATA.rxLive then
        DATA.ignited = false
        raiseAlarm("FLAMEOUT", "RX FLAMEOUT - FUEL ISOLATED", "alarm")
        paAmbient(nil)
        logEvent("REACTOR FLAMEOUT", ui.c.alarm)
    end
    DATA.injection = inj
    -- REAL ACTUATION: FCV/FV lineup drives the actual reactor via the
    -- REACTOR sensor node (which calls setInjectionRate on its port).
    if DATA.rxLive and paReady and inj ~= lastSentInj then
        rednet.broadcast({ type = "actuate", target = "REACTOR",
            set = "injection", value = inj }, "scada_actuate")
        logEvent("INJECTION DEMAND -> " .. inj .. " mB/t", ui.c.accentDim)
        lastSentInj = inj
    end
end

-- overlay live sensor telemetry onto plant data (real beats sim)
local function mergeTelemetry()
    local anyLive = false
    for i, t in ipairs(DATA.turbines) do
        local tel = telemetry["TB" .. i]
        if tel and os.clock() - tel.t < TELEM_FRESH and tel.turbine
            and tel.turbine.formed then
            local tb = tel.turbine
            t.live = true
            anyLive = true
            t.flow = tb.lastInput or tb.flow or 0
            -- Mekanism reports Joules; FE = J * 0.4 (verify vs your configs)
            t.prod = (tb.prod or 0) * 0.4
            t.steamPct = tb.steamPct or 0
            t.buffer = tb.energyPct or 0
            t.mode = tostring(tb.dump or "?"):gsub("DUMPING_EXCESS", "DUMP_EXC")
            if tel.tank and tel.tank.pct then
                t.water = tel.tank.pct
            else
                t.water = nil -- hot well not built/instrumented yet
            end
        else
            t.live = false
        end
    end
    if anyLive then
        local total = 0
        for _, t in ipairs(DATA.turbines) do total = total + (t.flow or 0) end
        DATA.steamFlow = total
    end
    -- reactor: any reachable port carries the whole multiblock's data
    DATA.rxLive = false
    local rt = telemetry["REACTOR"]
    if rt and os.clock() - rt.t < TELEM_FRESH and rt.readings then
        for _, e in pairs(rt.readings) do
            if e.getPlasmaTemperature ~= nil or e.isIgnited ~= nil then
                DATA.rxLive = true
                chInvalid = {}
                -- plausibility-validated assignment: hold last-good on junk
                local function qtemp(raw, maxV, key)
                    local v = ui.sane(raw)
                    if v <= 0 or v > math.max(ui.sane(maxV), 1) * 2 then
                        chInvalid[key] = true
                        return nil
                    end
                    return v
                end
                local function qpct(raw, key)
                    local v = ui.sane(raw)
                    if v > 1.5 and v <= 100.5 then
                        return v / 100 -- 0-100 scale source: normalize
                    elseif v < 0 or v > 1.001 then
                        chInvalid[key] = true
                        return nil
                    end
                    return v
                end
                if e.getPlasmaTemperature then
                    DATA.plasmaTemp = qtemp(e.getPlasmaTemperature,
                        DATA.maxPlasma, "plasma") or DATA.plasmaTemp
                end
                DATA.caseTemp = e.getCaseTemperature or DATA.caseTemp
                if e.isIgnited ~= nil then
                    DATA.ignited = (e.isIgnited == true)
                else
                    -- adapter doesn't report ignition: infer from physics.
                    -- burning plasma is megakelvin-scale; cold is ~300 K.
                    DATA.ignited = ui.sane(DATA.plasmaTemp) > 1e6
                end
                if e.getInjectionRate then DATA.injection = e.getInjectionRate end
                if e.getWaterFilledPercentage then
                    DATA.water = qpct(e.getWaterFilledPercentage, "water")
                        or DATA.water
                end
                if e.getSteamFilledPercentage then
                    DATA.steam = qpct(e.getSteamFilledPercentage, "steam")
                        or DATA.steam
                end
                -- Mekanism reports Joules; FE = J * 0.4
                if e.getProductionRate then
                    DATA.production = e.getProductionRate * 0.4
                end
                if e.getPassiveGeneration then
                    DATA.passiveGen = e.getPassiveGeneration * 0.4
                end
                break
            end
        end
        -- (reactor section continues below)
        -- backup online detection: reactor already burning (or link
        -- restored mid-run) lights the plant up without our sequence
        if DATA.rxLive then
            if not DATA.ignited then scramAt = nil end
            if DATA.ignited and not rxWasIgnited then
                logEvent("REACTOR REPORTING IGNITED - MODE 1", ui.c.ok)
                paAmbient("engine_room")
                -- adopt the lineup: reactor is burning, so the valves are
                -- open whatever this computer thought at boot
                if DATA.valves.fvd.pos < 99 or DATA.valves.fcv.pos < 2 then
                    DATA.valves.fvd.demand = 100; DATA.valves.fvd.pos = 100
                    DATA.valves.fvt.demand = 100; DATA.valves.fvt.pos = 100
                    local p = math.max(2, math.min(100,
                        (DATA.injection / 98) * 100))
                    DATA.valves.fcv.demand = p; DATA.valves.fcv.pos = p
                    saveValves()
                    logEvent("LINEUP ADOPTED FROM RUNNING REACTOR", ui.c.okDim)
                end
            elseif not DATA.ignited and rxWasIgnited then
                logEvent("REACTOR REPORTING SHUTDOWN", ui.c.warn)
                paAmbient(nil)
            end
            rxWasIgnited = DATA.ignited
        end
    end
    DATA.rxStale = (knownNodes["NODE_REACTOR"] == true) and not DATA.rxLive
    -- induction matrix: measured generation = what reaches the bus
    DATA.mtxLive = false
    local mt = telemetry["MATRIX"]
    if mt and os.clock() - mt.t < TELEM_FRESH and mt.readings then
        for _, e in pairs(mt.readings) do
            if e.getLastInput ~= nil or e.getMaxEnergy ~= nil then
                DATA.mtxLive = true
                local maxE = ui.sane(e.getMaxEnergy)
                if maxE > 0 then
                    DATA.matrix.energy = math.max(0, math.min(1,
                        ui.sane(e.getEnergy) / maxE))
                end
                -- Mekanism reports J/t; FE = J * 0.4
                DATA.matrix.input = ui.sane(e.getLastInput) * 0.4
                DATA.matrix.output = ui.sane(e.getLastOutput) * 0.4
                DATA.production = DATA.matrix.input
                break
            end
        end
    end
    -- tanks: AUTO-BIND by stored substance (no name mapping needed).
    -- a tank identifies itself by what's in it; empty tanks stay sim
    -- until they contain a trace of their substance.
    DATA.tanksLive = false
    local tt = telemetry["TANKS"]
    if tt and os.clock() - tt.t < TELEM_FRESH and tt.tanks then
        for _, tk in pairs(tt.tanks) do
            local nm = tostring(tk.content or ""):lower()
            local key
            if nm:find("deuterium") then key = "deut"
            elseif nm:find("tritium") then key = "trit"
            elseif nm:find("fusion") or nm:find("d_t") then key = "dtf"
            elseif nm:find("lithium") then key = "li"
            elseif nm:find("heavy") then key = "hw"
            elseif nm:find("water") then key = "stor" end
            if key then
                DATA.tanksLive = true
                local pct = tk.pct
                if tk.amount and tk.capacity and tk.capacity > 0 then
                    pct = tk.amount / tk.capacity -- ratio beats the API pct
                end
                pct = math.max(0, math.min(1, pct or 0))
                if key == "deut" then DATA.deut = pct
                elseif key == "trit" then DATA.trit = pct
                elseif key == "dtf" then DATA.dtfuel = pct
                else DATA.tanks[key] = pct end
                if tk.capacity and tk.capacity > 0 then
                    DATA.tankCaps[key] = tk.capacity
                end
                if key == "dtf" and tk.amount then
                    -- measured D-T feed to the core = supply tank drain rate
                    local pv = tankPrev.dtf
                    local now = os.clock()
                    if not pv then
                        tankPrev.dtf = { amt = tk.amount, t = now }
                    elseif now - pv.t >= 15 then
                        DATA.dtBurn = math.max(0,
                            (pv.amt - tk.amount) / ((now - pv.t) * 20))
                        tankPrev.dtf = { amt = tk.amount, t = now }
                    end
                end
                if (key == "deut" or key == "trit") and tk.amount then
                    local pv = tankPrev[key]
                    local now = os.clock()
                    if not pv then
                        tankPrev[key] = { amt = tk.amount, t = now }
                    elseif now - pv.t >= 15 then
                        local net = (tk.amount - pv.amt) / ((now - pv.t) * 20)
                        local burn = DATA.ignited and DATA.injection / 2 or 0
                        local prod = math.max(0, net + burn)
                        if key == "deut" then DATA.prodD = prod
                        else DATA.prodT = prod end
                        tankPrev[key] = { amt = tk.amount, t = now }
                    end
                end
            end
        end
    end
end

-- operating mode derives from measured state, never asserted
local function setMode()
    if DATA.ignited then
        if DATA.injection <= 4 then
            DATA.modeText = "MODE 1 - MIN SUSTAINING POWER"
        elseif DATA.injection < 98 then
            DATA.modeText = "MODE 2 - POWER OPERATION"
        else
            DATA.modeText = "MODE 3 - FULL POWER"
        end
    else
        DATA.modeText = "STANDBY - REACTOR SHUTDOWN"
    end
end

local function readData()
    valveTick()
    if not CONFIG.SIM then
        mergeTelemetry()
        setMode()
        evalAlarms()
        return
    end -- real peripherals wire in here later
    if DATA.ignited then
        DATA.plasmaTemp = approach(DATA.plasmaTemp, 120e6 + math.random(-2e6, 2e6), 0.07)
        DATA.caseTemp   = approach(DATA.caseTemp, 40e6 + math.random(-8e5, 8e5), 0.07)
        DATA.production = approach(DATA.production, 63.5e6 + math.random(-5e5, 5e5), 0.1)
        DATA.passiveGen = approach(DATA.passiveGen, 4.9e6, 0.1)
        DATA.envLoss    = 25000 + math.random(-600, 600)
        DATA.transferLoss = 11000 + math.random(-300, 300)
        DATA.steam  = clamp(DATA.steam + (math.random() - 0.48) * 0.02, 0.08, 0.95)
        DATA.water  = clamp(1 - DATA.steam * 0.8, 0.1, 0.98)
        DATA.deut   = clamp(DATA.deut - 0.0004 + math.random() * 0.0008, 0.05, 1)
        DATA.trit   = clamp(DATA.trit - 0.0004 + math.random() * 0.0008, 0.05, 1)
        DATA.dtfuel = clamp(DATA.dtfuel + (math.random() - 0.5) * 0.01, 0.1, 1)
        -- fuel production: sim only until real tank deltas take over
        if not DATA.tanksLive then
            DATA.prodD = approach(DATA.prodD, 52 + math.random(-1, 1), 0.1)
            DATA.prodT = approach(DATA.prodT,
                44 + 10 * math.sin(tick / 180) + math.random(-2, 2), 0.05)
        end
        DATA.tanks.li = clamp(DATA.tanks.li + (math.random() - 0.5) * 0.004, 0.1, 0.95)
        DATA.tanks.hw = clamp(DATA.tanks.hw + (math.random() - 0.5) * 0.004, 0.1, 0.95)
        DATA.tanks.stor = clamp(1 - DATA.steam * 0.5 + (math.random() - 0.5) * 0.02,
            0.2, 0.98)
        local totalFlow = 0
        for _, t in ipairs(DATA.turbines) do
            if t.online then
                t.flow = approach(t.flow, 14.7e6 / #DATA.turbines + math.random(-30000, 30000), 0.15)
                t.prod = t.flow * 4 -- ~4 FE per mB at full blades/coils
                t.steamPct = clamp(0.3 + math.random() * 0.15, 0, 1)
                t.buffer = clamp(t.buffer + (math.random() - 0.5) * 0.05, 0.1, 0.95)
                t.mode = "DUMP_EXC"
                if t.flow > 100 then
                    t.water = clamp(approach(t.water or 0.55, 0.55, 0.05)
                        + (math.random() - 0.5) * 0.04, 0.05, 0.95)
                else
                    -- steaming without flow: hot well dries out
                    t.water = clamp(t.water - 0.01, 0.02, 1)
                end
            else
                t.flow = approach(t.flow, 0, 0.3); t.prod = 0
                t.steamPct = approach(t.steamPct, 0, 0.1)
                t.mode = "IDLE"
            end
            totalFlow = totalFlow + t.flow
        end
        DATA.steamFlow = totalFlow
        DATA.matrix.input  = DATA.production
        DATA.matrix.output = DATA.production * (0.9 + math.random() * 0.1)
        DATA.matrix.energy = clamp(DATA.matrix.energy +
            (DATA.matrix.input - DATA.matrix.output) / 5e9, 0.05, 0.99)
        for i = 1, 4 do DATA.lasers[i] = clamp(DATA.lasers[i] + 0.005, 0, 0.3) end
    else
        DATA.plasmaTemp = approach(DATA.plasmaTemp, 300, 0.1)
        DATA.caseTemp   = approach(DATA.caseTemp, 300, 0.1)
        DATA.production = approach(DATA.production, 0, 0.2)
        DATA.passiveGen = approach(DATA.passiveGen, 0, 0.2)
        DATA.envLoss    = approach(DATA.envLoss, 0, 0.2)
        DATA.transferLoss = approach(DATA.transferLoss, 0, 0.2)
        DATA.steamFlow  = approach(DATA.steamFlow, 0, 0.2)
        for _, t in ipairs(DATA.turbines) do
            t.flow = approach(t.flow, 0, 0.2); t.prod = 0; t.mode = "IDLE"
        end
        for i = 1, 4 do DATA.lasers[i] = clamp(DATA.lasers[i] + 0.01, 0, 1) end
    end
    mergeTelemetry()
    setMode()
    rpsAction()
    push(hist.plasma, DATA.plasmaTemp); push(hist.case, DATA.caseTemp)
    push(hist.prod, DATA.production);   push(hist.flow, DATA.steamFlow)
    evalAlarms()
end

---------------------------------------------------------------
-- LAYOUT
---------------------------------------------------------------
local W, H = scr.w, scr.h
local CB = {}
local function layout()
    W, H = scr.w, scr.h
    local sideW = math.floor(W * 0.24)
    CB.sideW = sideW
    CB.x1, CB.x2 = sideW + 3, W - sideW - 3
    CB.y1, CB.y2 = 5, H - 12
    CB.cx = math.floor((CB.x1 + CB.x2) / 2)
    CB.cy = math.floor((CB.y1 + CB.y2) / 2)
    CB.cut = math.floor(math.min((CB.y2 - CB.y1) * 0.22, (CB.x2 - CB.x1) * 0.15))
end
layout()

---------------------------------------------------------------
-- CHROME (header tabs + master control strip)
---------------------------------------------------------------
local PAGES = { "CORE", "PARAMS", "STEAM", "ALARMS", "SETUP" }

-- commissioning roster: nodes heard on scada_hello, PA probed on scada_pa
local roster = {}
local paInfo = { n = 0, t = -100 }
local VERSION = "2026.08.12-1"
local STALE_S = 15           -- seconds without heartbeat = link lost (debounced vs lag spikes)

-- nodes remembered across reboots so disconnects are detected, not forgotten
local knownNodes = {}
do
    if fs.exists("known_nodes") then
        local f = fs.open("known_nodes", "r")
        knownNodes = textutils.unserialize(f.readAll()) or {}
        f.close()
    end
end
local function saveKnown()
    local f = fs.open("known_nodes", "w")
    f.write(textutils.serialize(knownNodes))
    f.close()
end
-- sensors the plant EXPECTS: never-seen counts as loss of indication.
-- extend this list as the plant grows (TANKS, FUEL, MATRIX, TB3...).
local EXPECTED_SENSORS = {
    "NODE_REACTOR", "NODE_TB1", "NODE_TB2", "NODE_TANKS", "NODE_MATRIX",
    -- (no FUEL node: production rates get computed from tank deltas
    --  once the TANKS node is bound)
}
for _, r in ipairs(EXPECTED_SENSORS) do knownNodes[r] = true end

local nodeUp = {}   -- role -> bool (last evaluated link state)

local function nodeWatch()
    loiList = {}
    for role in pairs(knownNodes) do
        local t = roster[role]
        local up = t ~= nil and os.clock() - t < STALE_S
        if nodeUp[role] == true and not up then
            logEvent(role .. " LINK LOST", ui.c.alarm)
        elseif nodeUp[role] == false and up then
            logEvent(role .. " LINK RESTORED", ui.c.okDim)
        end
        nodeUp[role] = up
        if not up then loiList[role] = true end
    end
end

local function drawChrome()
    -- header
    scr:fill(1, 1, W, 3, ui.c.panel)
    scr:text(3, 1, "FUSION FACILITY - UNIT 1", ui.c.accent, ui.c.panel)
    scr:text(W - 10, 1, os.date("%H:%M:%S"), ui.c.accentDim, ui.c.panel)
    local status, sc = "STANDBY", ui.c.dim
    if igniting then status, sc = "IGNITION SEQUENCE IN PROGRESS", ui.c.warn
    elseif DATA.ignited then status, sc = DATA.modeText or "MODE 1", ui.c.ok end
    scr:center(1, W, 1, status, sc, ui.c.panel)
    -- alarm badge
    local n = unackedCount()
    if n > 0 then
        local bc = flash and ui.c.alarm or ui.c.panel
        scr:text(W - 22, 1, " ALM " .. n .. " ", ui.c.text, bc)
    end
    -- tabs
    local tw = math.floor(W / #PAGES)
    for i, p in ipairs(PAGES) do
        local x1 = (i - 1) * tw + 1
        local x2 = (i == #PAGES) and W or i * tw
        local active = (p == page)
        local bg = active and ui.c.bg or ui.c.line
        scr:fill(x1, 2, x2 - 1, 3, bg)
        scr:center(x1, x2 - 1, 2, p, active and ui.c.accent or ui.c.text, bg)
        if p == "ALARMS" and n > 0 and flash then
            scr:center(x1, x2 - 1, 3, string.rep("!", math.min(n, 5)), ui.c.alarm, bg)
        end
        scr.touches[#scr.touches + 1] =
            { x1 = x1, y1 = 2, x2 = x2 - 1, y2 = 3, action = "page:" .. p }
    end
    -- master control strip
    local by = H - 3
    scr:fill(1, by - 1, W, H, ui.c.panel)
    local V = DATA.valves
    local function vs(v)
        if v.pos > 99 then return "OPEN", ui.c.ok
        elseif v.pos < 1 then return "SHUT", ui.c.alarm end
        return math.floor(v.pos) .. "%", ui.c.caution
    end
    local ds, dc = vs(V.fvd)
    local ts, tc = vs(V.fvt)
    scr:text(3, by, "FV-D ", ui.c.dim, ui.c.panel)
    scr:text(8, by, ds, dc, ui.c.panel)
    scr:text(14, by, "FV-T ", ui.c.dim, ui.c.panel)
    scr:text(19, by, ts, tc, ui.c.panel)
    scr:text(26, by, ("FCV %3d%%   INJ %d mB/t"):format(V.fcv.pos, DATA.injection),
        ui.c.text, ui.c.panel)
    if DATA.runback then
        scr:text(50, by, "RUNBACK", ui.c.warn, ui.c.panel)
    end
    if DATA.battleshort and flash then
        scr:text(60, by, " ** BATTLESHORT ** ", ui.c.text, ui.c.alarm)
    end
    local bw = math.floor(W * 0.08)
    scr:button(3, by + 1, 3 + bw, by + 2, "FV-D", ui.c.line, "fvd", true)
    scr:button(5 + bw, by + 1, 5 + 2 * bw, by + 2, "FV-T", ui.c.line, "fvt", true)
    scr:button(7 + 2 * bw, by + 1, 7 + 3 * bw, by + 2, "FCV-", ui.c.line, "fcvDown", true)
    scr:button(9 + 3 * bw, by + 1, 9 + 4 * bw, by + 2, "FCV+", ui.c.line, "fcvUp", true)
    scr:button(W - 3 * bw - 8, by, W - 2 * bw - 8, by + 2, "ACK ALL",
        ui.c.warnDim, "ack", unackedCount() > 0)
    scr:button(W - 2 * bw - 5, by, W - bw - 5, by + 2, "IGNITE",
        ui.c.okDim, "ignite", not DATA.ignited and not igniting)
    scr:button(W - bw - 2, by, W - 2, by + 2, "SCRAM",
        ui.c.alarm, "scram", DATA.ignited)
end

---------------------------------------------------------------
-- PAGE: CORE
---------------------------------------------------------------
local bBG, bWhite = colors.toBlit(ui.c.bg), colors.toBlit(colors.white)
local bHot, bPlasma = colors.toBlit(ui.c.plasmaHot), colors.toBlit(ui.c.plasma)
local bDim = colors.toBlit(ui.c.plasmaDim)

local function drawPlasmaField(intensity)
    local ix1, iy1, ix2, iy2 = CB.x1 + 1, CB.y1 + 1, CB.x2 - 1, CB.y2 - 1
    local rx = (ix2 - ix1) / 2 * 0.82 * math.max(intensity, 0.001)
    local ry = (iy2 - iy1) / 2 * 0.82 * math.max(intensity, 0.001)
    for y = iy1, iy2 do
        local row = {}
        local dy = (y - CB.cy) / math.max(ry, 0.001)
        for x = ix1, ix2 do
            local dx = (x - CB.cx) / math.max(rx, 0.001)
            local d = math.sqrt(dx * dx + dy * dy)
            local ch = bBG
            if intensity > 0.02 and d <= 1.15 then
                local t = d + (math.random() - 0.5) * 0.14
                if t < 0.18 then ch = bWhite
                elseif t < 0.40 then ch = bHot
                elseif t < 0.68 then ch = bPlasma
                elseif t < 0.95 then ch = bDim
                elseif t < 1.08 and math.random() < 0.35 then ch = bDim end
            end
            row[#row + 1] = ch
        end
        scr:blitRow(ix1, y, table.concat(row))
    end
    if intensity > 0.5 then
        for k = 0, 2 do
            local ang = tick * 0.35 + k * (math.pi * 2 / 3)
            for step = 0, 6 do
                local rr = 0.95 + step * 0.06
                local wob = math.sin(tick * 0.9 + step * 0.8 + k) * 0.12
                local x = CB.cx + math.floor(math.cos(ang + wob) * rx * rr + 0.5)
                local y = CB.cy + math.floor(math.sin(ang + wob) * ry * rr + 0.5)
                if x > ix1 and x < ix2 and y > iy1 and y < iy2 then
                    scr:px(x, y, step < 3 and ui.c.plasmaHot or ui.c.plasmaDim)
                end
            end
        end
    end
end

local function drawChamber()
    local x1, y1, x2, y2, cut = CB.x1, CB.y1, CB.x2, CB.y2, CB.cut
    local cw = cut * 2
    scr:fill(x1 + cw, y1, x2 - cw, y1, ui.c.line)
    scr:fill(x1 + cw, y2, x2 - cw, y2, ui.c.line)
    scr:fill(x1, y1 + cut, x1, y2 - cut, ui.c.line)
    scr:fill(x2, y1 + cut, x2, y2 - cut, ui.c.line)
    for i = 0, cut do
        local off = math.floor(cw * i / cut)
        scr:px(x1 + cw - off, y1 + i, ui.c.line); scr:px(x1 + cw - off + 1, y1 + i, ui.c.line)
        scr:px(x2 - cw + off, y1 + i, ui.c.line); scr:px(x2 - cw + off - 1, y1 + i, ui.c.line)
        scr:px(x1 + cw - off, y2 - i, ui.c.line); scr:px(x1 + cw - off + 1, y2 - i, ui.c.line)
        scr:px(x2 - cw + off, y2 - i, ui.c.line); scr:px(x2 - cw + off - 1, y2 - i, ui.c.line)
    end
    scr:fill(CB.cx - 3, y1, CB.cx + 3, y1, ui.c.accent)
    scr:center(CB.cx - 10, CB.cx + 10, y1 - 1, "LASER FOCUS MATRIX", ui.c.accentDim)
    local pm = math.floor((y1 + y2) / 2)
    scr:fill(x1, pm - 1, x1, pm + 1, ui.c.water)
    scr:text(x1 - 9, pm, "WATER IN", ui.c.water)
    scr:fill(x2, pm - 1, x2, pm + 1, ui.c.steam)
    scr:text(x2 + 2, pm, "STEAM OUT", ui.c.steam)
    scr:fill(CB.cx - 2, y2, CB.cx + 2, y2, ui.c.ok)
    scr:center(CB.cx - 10, CB.cx + 10, y2 + 1, "D-T INJECTION", ui.c.okDim)
end

local function graphPanel(x1, y1, x2, y2, title, series, value, colour, maxV)
    scr:panel(x1, y1, x2, y2, title)
    scr:text(x1 + 2, y1 + 1, value, colour, ui.c.panel)
    local gh = y2 - y1 - 3
    if gh >= 2 then
        if maxV then
            scr:sparkAbs(x1 + 2, y1 + 3, x2 - x1 - 3, gh, series, maxV, colour)
        else
            scr:spark(x1 + 2, y1 + 3, x2 - x1 - 3, gh, series, colour)
        end
    end
end

-- value / limit readout with margin colour
local function limitVal(v, maxV)
    local frac = ui.sane(v) / math.max(ui.sane(maxV), 1)
    local c = ui.c.ok
    if frac >= 0.95 then c = ui.c.alarm
    elseif frac >= 0.85 then c = ui.c.warn end
    return ("%s / %s  %d%%"):format(ui.si(v, "K"), ui.si(maxV, "K"),
        math.floor(frac * 100 + 0.5)), c
end

local function renderCore()
    local intensity = 0
    if DATA.ignited then intensity = 0.88 + math.random() * 0.12 end
    drawPlasmaField(intensity)
    drawChamber()
    local lh = math.floor((H - 18) / 2)
    local pv, pc = limitVal(DATA.plasmaTemp, DATA.maxPlasma)
    graphPanel(2, 5, CB.sideW, 4 + lh, "PLASMA TEMP", hist.plasma, pv, pc,
        DATA.maxPlasma)
    local cv, cc = limitVal(DATA.caseTemp, DATA.maxCase)
    graphPanel(2, 6 + lh, CB.sideW, 5 + 2 * lh, "CASE TEMP", hist.case, cv, cc,
        DATA.maxCase)
    graphPanel(rx1, 5, W - 1, 4 + lh,
        DATA.mtxLive and "GENERATION (MATRIX INPUT)" or "NET PRODUCTION (SIM)",
        hist.prod, ui.si(DATA.production, "FE/t"), ui.c.caution)
    local expFlow = math.max(DATA.injection * 150000, 1e6)
    graphPanel(rx1, 6 + lh, W - 1, 5 + 2 * lh, "STEAM FLOW vs EXPECTED",
        hist.flow, ui.si(DATA.steamFlow, "mB/t") .. " / "
        .. ui.si(expFlow, ""), ui.c.accentDim, expFlow * 1.15)
    -- inventory strip above master control
    local sy = H - 9
    scr:panel(2, sy, W - 1, H - 5, "INVENTORY")
    local names = {"WATER", "STEAM", "DEUTERIUM", "TRITIUM", "D-T FUEL"}
    local vals  = {DATA.water, DATA.steam, DATA.deut, DATA.trit, DATA.dtfuel}
    local cols  = {ui.c.water, ui.c.steam, ui.c.accent, ui.c.ok, ui.c.okDim}
    local gw = math.floor((W - 10) / 5)
    for i = 1, 5 do
        scr:gaugeH(4 + (i - 1) * (gw + 1), sy + 2, gw - 2,
            names[i], vals[i], ui.pct(vals[i]), cols[i])
    end
end

---------------------------------------------------------------
-- PAGE: PARAMS (dense grid, limits, trend arrows)
---------------------------------------------------------------
-- limit spec: {loAlm, loWarn, hiWarn, hiAlm} (nil = unchecked)
local function limitColour(v, lim)
    if not lim then return ui.c.text end
    if (lim[1] and v < lim[1]) or (lim[4] and v > lim[4]) then return ui.c.alarm end
    if (lim[2] and v < lim[2]) or (lim[3] and v > lim[3]) then return ui.c.warn end
    return ui.c.text
end

local function paramRow(x, y, w, label, key, value, unit, lim, fmtFn)
    local a, ac = arrow(key, value)
    local vs = (fmtFn or ui.si)(value, "")
    scr:text(x, y, label, ui.c.dim)
    scr:text(x + w - #unit - #vs - 3, y, vs, limitColour(value, lim))
    scr:text(x + w - #unit - 2, y, unit, ui.c.dim)
    scr:text(x + w - 1, y, a, ac)
end

local function renderParams()
    scr:panel(2, 5, W - 1, H - 5, "REACTOR PLANT PARAMETERS")
    local colW = math.floor((W - 8) / 3)
    local c1, c2, c3 = 4, 6 + colW, 8 + 2 * colW
    local y0 = 7
    local fpct = function(v) return string.format("%.1f", v * 100) end
    local fraw = function(v) return string.format("%.0f", v) end

    scr:text(c1, y0 - 1, "-- CORE --", ui.c.accent)
    paramRow(c1, y0,     colW, "PLASMA TEMP", "pt", DATA.plasmaTemp, "K",
        {nil, nil, 0.85 * DATA.maxPlasma, 0.95 * DATA.maxPlasma})
    paramRow(c1, y0 + 1, colW, "PLASMA TEMP LIMIT", "ptl", DATA.maxPlasma, "K")
    paramRow(c1, y0 + 2, colW, "CASE TEMP", "ct", DATA.caseTemp, "K",
        {nil, nil, 0.85 * DATA.maxCase, 0.95 * DATA.maxCase})
    paramRow(c1, y0 + 3, colW, "CASE TEMP LIMIT", "ctl", DATA.maxCase, "K")
    paramRow(c1, y0 + 4, colW, "PLASMA-CASE dT", "dt",
        DATA.plasmaTemp - DATA.caseTemp, "K")
    paramRow(c1, y0 + 5, colW, "IGNITION TEMP", "it", DATA.ignitionTemp, "K")
    paramRow(c1, y0 + 6, colW, "ENV HEAT LOSS", "el", DATA.envLoss, "K/t")
    paramRow(c1, y0 + 7, colW, "XFER HEAT LOSS", "tl", DATA.transferLoss, "K/t")
    scr:text(c1, y0 + 9, "-- BURN --", ui.c.accent)
    paramRow(c1, y0 + 10, colW, "INJECTION RATE", "ir", DATA.injection, "mB/t", nil, fraw)
    paramRow(c1, y0 + 11, colW, "D CONSUMPTION", "dc", DATA.injection / 2, "mB/t", nil, fraw)
    paramRow(c1, y0 + 12, colW, "T CONSUMPTION", "tc", DATA.injection / 2, "mB/t", nil, fraw)
    scr:text(c1, y0 + 14, "HOHLRAUM: " .. (DATA.hohlraum and "LOADED" or "EMPTY"),
        DATA.hohlraum and ui.c.ok or ui.c.alarm)

    scr:text(c2, y0 - 1, "-- INVENTORY --", ui.c.accent)
    paramRow(c2, y0,     colW, "RX WATER LEVEL", "wl", DATA.water, "%", {0.15, 0.30}, fpct)
    paramRow(c2, y0 + 1, colW, "RX STEAM LEVEL", "sl", DATA.steam, "%",
        {nil, nil, 0.80, 0.92}, fpct)
    paramRow(c2, y0 + 2, colW, "DEUTERIUM TANK", "dtk", DATA.deut, "%", {0.05, 0.15}, fpct)
    paramRow(c2, y0 + 3, colW, "TRITIUM TANK", "ttk", DATA.trit, "%", {0.05, 0.15}, fpct)
    paramRow(c2, y0 + 4, colW, "D-T FUEL TANK", "dttk", DATA.dtfuel, "%", {0.15, 0.30}, fpct)
    scr:text(c2, y0 + 6, "-- LASER BANKS --", ui.c.accent)
    for i = 1, 4 do
        paramRow(c2, y0 + 6 + i, colW, "BANK " .. string.char(64 + i) .. " CHARGE",
            "lb" .. i, DATA.lasers[i], "%", {0.3, 0.5}, fpct)
    end
    scr:text(c2, y0 + 12, "-- STEAM CYCLE --", ui.c.accent)
    paramRow(c2, y0 + 13, colW, "TOTAL STEAM FLOW", "tsf", DATA.steamFlow, "mB/t")
    paramRow(c2, y0 + 14, colW, "EXPECTED FLOW", "esf",
        DATA.ignited and DATA.injection * 150000 or 0, "mB/t")

    scr:text(c3, y0 - 1, "-- ELECTRICAL --", ui.c.accent)
    paramRow(c3, y0,     colW, "GROSS PRODUCTION", "gp", DATA.production, "FE/t")
    paramRow(c3, y0 + 1, colW, "RX PASSIVE GEN", "pg", DATA.passiveGen, "FE/t")
    paramRow(c3, y0 + 2, colW, "MATRIX INPUT", "mi", DATA.matrix.input, "FE/t")
    paramRow(c3, y0 + 3, colW, "MATRIX OUTPUT", "mo", DATA.matrix.output, "FE/t")
    paramRow(c3, y0 + 4, colW, "MATRIX CHARGE", "mc", DATA.matrix.energy, "%",
        {0.05, 0.10, 0.95, 0.99}, fpct)
    scr:text(c3, y0 + 6, "-- HEAT BALANCE --", ui.c.accent)
    local theo = DATA.ignited and math.max(1, DATA.injection * 650000) or 1
    paramRow(c3, y0 + 7, colW, "THERMAL EFF", "te",
        DATA.production / theo, "%", {0.5, 0.7}, fpct)
    paramRow(c3, y0 + 8, colW, "LOSS FRACTION", "lf",
        (DATA.envLoss + DATA.transferLoss) / math.max(DATA.plasmaTemp, 1), "", nil,
        function(v) return string.format("%.5f", v) end)
    scr:text(c3, y0 + 10, "-- UNIT STATUS --", ui.c.accent)
    scr:text(c3, y0 + 11, "MODE: " .. (DATA.ignited and "1 PWR OP" or "5 STANDBY"),
        DATA.ignited and ui.c.ok or ui.c.dim)
    scr:text(c3, y0 + 12, "TURBINES ONLINE: " .. (function()
        local n = 0
        for _, t in ipairs(DATA.turbines) do if t.online then n = n + 1 end end
        return n
    end)() .. "/" .. #DATA.turbines, ui.c.text)
    scr:text(c3, y0 + 13, "ACTIVE ALARMS: " .. (function()
        local n = 0; for _ in pairs(alarmState) do n = n + 1 end; return n
    end)(), unackedCount() > 0 and ui.c.alarm or ui.c.dim)
end

---------------------------------------------------------------
-- PAGE: STEAM (turbine table + matrix)
---------------------------------------------------------------
local function renderSteam()
    scr:panel(2, 5, W - 1, H - 12, "TURBINE HALL - 6 UNITS")
    local cols = { 4, 12, 26, 40, 54, 64, 74, 88 }
    local heads = { "UNIT", "STATUS", "FLOW mB/t", "PROD FE/t", "STM %", "BUF %", "DUMP", "SG LVL (GREEN BAND 40-70)" }
    for i, hd in ipairs(heads) do scr:text(cols[i], 7, hd, ui.c.accent, ui.c.panel) end
    scr:fill(4, 8, W - 4, 8, ui.c.line)
    local totalFlow, totalProd = 0, 0
    for i, t in ipairs(DATA.turbines) do
        local y = 8 + i * 2
        local status, sc = "ONLINE", ui.c.ok
        if not t.online then status, sc = "ISOLATED", ui.c.alarm
        elseif t.flow < 100 and DATA.ignited then status, sc = "TRIPPED", ui.c.warn
        elseif not DATA.ignited then status, sc = "STANDBY", ui.c.dim end
        scr:text(cols[1], y, "TB-" .. i, ui.c.text, ui.c.panel)
        scr:text(cols[2], y, status, sc, ui.c.panel)
        scr:text(cols[3], y, ui.si(t.flow, ""), ui.c.steam, ui.c.panel)
        scr:text(cols[4], y, ui.si(t.prod, ""), ui.c.caution, ui.c.panel)
        scr:text(cols[5], y, ui.pct(t.steamPct), ui.c.text, ui.c.panel)
        scr:text(cols[6], y, ui.pct(t.buffer), ui.c.text, ui.c.panel)
        scr:text(cols[7], y, t.mode, ui.c.dim, ui.c.panel)
        if t.water == nil then
            scr:text(cols[8], y, "NO INSTR (hot well pending)", ui.c.dim, ui.c.panel)
        else
            scr:bandBar(cols[8], y, 22, t.water, 0.40, 0.70)
            scr:text(cols[8] + 24, y, ui.pct(t.water), ui.c.text, ui.c.panel)
        end
        -- isolate/restore touch button per unit
        scr:button(W - 16, y, W - 6, y, t.online and "ISOLATE" or "RESTORE",
            t.online and ui.c.warnDim or ui.c.okDim, "tb:" .. i, true)
        totalFlow = totalFlow + t.flow
        totalProd = totalProd + t.prod
    end
    local ty = 10 + #DATA.turbines * 2 + 2
    scr:fill(4, ty - 1, W - 4, ty - 1, ui.c.line)
    scr:text(cols[1], ty, "TOTAL", ui.c.accent, ui.c.panel)
    scr:text(cols[3], ty, ui.si(totalFlow, ""), ui.c.steam, ui.c.panel)
    scr:text(cols[4], ty, ui.si(totalProd, ""), ui.c.caution, ui.c.panel)

    scr:panel(2, H - 10, W - 1, H - 5, "INDUCTION MATRIX / SWITCHYARD")
    local gw = math.floor((W - 12) / 3)
    scr:gaugeH(4, H - 8, gw, "CHARGE", DATA.matrix.energy,
        ui.pct(DATA.matrix.energy), ui.c.caution)
    scr:text(8 + gw, H - 8, "INPUT  " .. ui.si(DATA.matrix.input, "FE/t"), ui.c.ok, ui.c.panel)
    scr:text(8 + gw, H - 7, "OUTPUT " .. ui.si(DATA.matrix.output, "FE/t"), ui.c.warn, ui.c.panel)
    scr:text(12 + 2 * gw, H - 8, "GRID: TIED", ui.c.ok, ui.c.panel)
end

---------------------------------------------------------------
-- PAGE: ALARMS
---------------------------------------------------------------
local function renderAlarms()
    W, H = scr.w, scr.h
    local perRow = 4
    local tw = math.floor((W - 8) / perRow)
    local big = H >= 50
    local th = big and 3 or 2
    local gap = th + 1
    local rows = math.ceil(#ALARM_DEFS / perRow)
    local gridBot = 6 + rows * gap
    scr:panel(2, 5, W - 1, gridBot + 1, "ANNUNCIATOR")
    for i, def in ipairs(ALARM_DEFS) do
        local row = math.floor((i - 1) / perRow)
        local col = (i - 1) % perRow
        local x1 = 4 + col * tw
        local y1 = 7 + row * gap
        local a = alarmState[def.id]
        local state = "off"
        if a then state = a.acked and "warn" or a.state end
        scr:tile(x1, y1, x1 + tw - 2, y1 + th - 1, def.label, state, flash)
    end
    scr:panel(2, gridBot + 3, W - 1, H - 5, "ALARM / EVENT LOG")
    local ly = gridBot + 5
    local maxRows = H - 6 - ly
    for i = 1, math.min(#alarmLog, maxRows) do
        local e = alarmLog[i]
        scr:text(4, ly + i - 1, e.time .. "  " .. e.text, e.colour, ui.c.panel)
    end
    if #alarmLog == 0 then
        scr:text(4, ly, "NO EVENTS LOGGED", ui.c.dim, ui.c.panel)
    end
end

---------------------------------------------------------------
-- PAGE: SETUP (commissioning - shows hookup status live)
---------------------------------------------------------------
local function renderSetup()
    W, H = scr.w, scr.h
    scr:panel(2, 4, W - 1, H - 5, "SETUP / COMMISSIONING  v" .. VERSION)
    local y = 6
    scr:text(4, y, "-- THIS COMPUTER --", ui.c.accent, ui.c.panel)
    scr:text(30, y, "UPTIME " .. math.floor(os.clock()) .. "s",
        ui.c.dim, ui.c.panel)
    y = y + 1
    scr:text(4, y, "MONITOR " .. W .. "x" .. H, ui.c.ok, ui.c.panel)
    scr:text(22, y, "MODEM " .. (paReady and "OPEN" or "MISSING"),
        paReady and ui.c.ok or ui.c.alarm, ui.c.panel)
    local spk
    for _, s2 in ipairs({ "top", "bottom", "left", "right", "front", "back" }) do
        if peripheral.getType(s2) == "speaker" then spk = true break end
    end
    scr:text(38, y, "SPEAKER " .. (spk and "LOCAL" or "NONE"),
        spk and ui.c.ok or ui.c.caution, ui.c.panel)
    y = y + 2

    scr:text(4, y, "-- NODES (auto-learned, persisted) --", ui.c.accent, ui.c.panel)
    y = y + 1
    local ordered = {}
    for role in pairs(knownNodes) do ordered[#ordered + 1] = role end
    table.sort(ordered)
    if #ordered == 0 then
        scr:text(4, y, "NONE HEARD YET", ui.c.dim, ui.c.panel)
        y = y + 1
    end
    for _, role in ipairs(ordered) do
        if y > H - 14 then break end
        local t = roster[role]
        local up = t and os.clock() - t < STALE_S
        scr:text(4, y, role, ui.c.text, ui.c.panel)
        if up then
            scr:text(26, y, "ONLINE", ui.c.ok, ui.c.panel)
            scr:text(34, y, math.floor(os.clock() - t) .. "s ago",
                ui.c.dim, ui.c.panel)
        else
            scr:loiBox(26, y, 8, "LOI")
            scr:text(36, y, t and (math.floor(os.clock() - t) .. "s silent")
                or "never seen", ui.c.alarm, ui.c.panel)
        end
        y = y + 1
    end
    local paOk = os.clock() - paInfo.t < 15
    scr:text(4, y, "PA AUDIO", ui.c.text, ui.c.panel)
    if paOk then
        scr:text(26, y, "ONLINE", ui.c.ok, ui.c.panel)
        scr:text(34, y, paInfo.n .. " sounds", ui.c.dim, ui.c.panel)
    else
        scr:loiBox(26, y, 8, "LOI")
    end
    y = y + 2

    scr:text(4, y, "-- REACTOR LINK (raw adapter fields) --", ui.c.accent,
        ui.c.panel)
    y = y + 1
    local rt = telemetry["REACTOR"]
    if rt and rt.readings then
        local shown = 0
        for _, e in pairs(rt.readings) do
            local keys = {}
            for k in pairs(e) do
                if k ~= "type" then keys[#keys + 1] = k end
            end
            table.sort(keys)
            for _, k in ipairs(keys) do
                if shown >= 8 or y > H - 22 then break end
                local v = e[k]
                if type(v) == "number" then v = ui.si(v, "") end
                scr:text(4, y, k:gsub("^get", ""):sub(1, 24), ui.c.dim,
                    ui.c.panel)
                scr:text(30, y, tostring(v):sub(1, 18), ui.c.text, ui.c.panel)
                y = y + 1
                shown = shown + 1
            end
            if shown > 0 then break end
        end
        if shown == 0 then
            scr:text(4, y, "CONNECTED, NO FIELDS", ui.c.alarm, ui.c.panel)
            y = y + 1
        end
    else
        scr:text(4, y, "NO REACTOR TELEMETRY", ui.c.alarm, ui.c.panel)
        y = y + 1
    end
    y = y + 1
    scr:text(4, y, "-- TANK BINDINGS (TANKS node) --", ui.c.accent, ui.c.panel)
    y = y + 1
    local tt = telemetry["TANKS"]
    if tt and tt.tanks then
        for nm2, tk in pairs(tt.tanks) do
            if y > H - 16 then break end
            local c2 = tostring(tk.content or "EMPTY")
            local key = "UNMATCHED"
            local low = c2:lower()
            if low:find("fusion") or low:find("d_t") then key = "D-T FUEL"
            elseif low:find("deuterium") then key = "DEUTERIUM"
            elseif low:find("tritium") then key = "TRITIUM"
            elseif low:find("lithium") then key = "LITHIUM"
            elseif low:find("heavy") then key = "HEAVY WATER"
            elseif low:find("water") then key = "WATER STG" end
            scr:text(4, y, nm2:sub(1, 20), ui.c.dim, ui.c.panel)
            scr:text(26, y, c2:gsub("^.*:", ""):sub(1, 14), ui.c.text, ui.c.panel)
            scr:text(42, y, key, key == "UNMATCHED" and ui.c.alarm or ui.c.ok,
                ui.c.panel)
            y = y + 1
        end
    else
        scr:text(4, y, "NO TANKS TELEMETRY", ui.c.alarm, ui.c.panel)
        y = y + 1
    end
    y = y + 1
    scr:text(4, y, "-- WIRED PERIPHERALS --", ui.c.accent, ui.c.panel)
    y = y + 1
    local counts, order = {}, {}
    for _, n in ipairs(peripheral.getNames()) do
        local ty = peripheral.getType(n) or "?"
        if not counts[ty] then counts[ty] = 0; order[#order + 1] = ty end
        counts[ty] = counts[ty] + 1
    end
    if #order == 0 then
        scr:text(4, y, "NONE ON NETWORK", ui.c.alarm, ui.c.panel)
        y = y + 1
    else
        for _, ty in ipairs(order) do
            if y > H - 7 then break end
            scr:text(4, y, ty .. "  x" .. counts[ty], ui.c.text, ui.c.panel)
            y = y + 1
        end
    end
    y = y + 1
    scr:text(4, y, "LOI = white box; alarms raise on any link loss.",
        ui.c.accentDim, ui.c.panel)
    scr:text(4, y + 1, "Nodes register on first heartbeat; reboot-safe.",
        ui.c.accentDim, ui.c.panel)
end

---------------------------------------------------------------
-- RENDER DISPATCH
---------------------------------------------------------------
---------------------------------------------------------------
-- NETWORK: state snapshots for consoles + side displays
---------------------------------------------------------------
local lastCast = 0

local function broadcastState()
    if not paReady then return end -- true when any modem is open
    local alarms = {}
    for _, def in ipairs(ALARM_DEFS) do
        local a = alarmState[def.id]
        if a then
            alarms[#alarms + 1] = { id = def.id, label = def.label,
                state = a.state, acked = a.acked }
        end
    end
    local log = {}
    for i = 1, math.min(#alarmLog, 8) do log[i] = alarmLog[i] end
    rednet.broadcast({
        type = "state", data = DATA, igniting = igniting,
        alarms = alarms, log = log, unacked = unackedCount(),
        firstOut = firstOut,
        seq = seqStage and { stage = seqStage, info = seqInfo } or nil,
        loi = loiList,
        chInvalid = chInvalid,
    }, "scada_state")
end

local function render(overlayFn)
    if os.clock() - lastCast > 0.3 then
        lastCast = os.clock()
        broadcastState()
    end
    scr:beginFrame()
    if page == "CORE" then renderCore()
    elseif page == "PARAMS" then renderParams()
    elseif page == "STEAM" then renderSteam()
    elseif page == "ALARMS" then renderAlarms()
    elseif page == "SETUP" then renderSetup() end
    drawChrome()
    if overlayFn then overlayFn() end
    scr:flush()
end

---------------------------------------------------------------
-- IGNITION SEQUENCE (runs on CORE page)
---------------------------------------------------------------
-- during the sequence the master wall stands down: simple status
-- frames only, pointing everyone at the center display cinematic.
local function seqScreen(sub, extra)
    tick = tick + 1
    scr:beginFrame()
    local midY = math.floor(H / 2)
    local on = (tick % 4) < 2
    scr:center(1, W, midY - 4, "IGNITION SEQUENCE IN PROGRESS",
        on and ui.c.warn or ui.c.line)
    scr:center(1, W, midY - 1, sub or "", ui.c.text)
    if extra then scr:center(1, W, midY + 1, extra, ui.c.dim) end
    scr:center(1, W, midY + 5, "EYES ON CENTER DISPLAY", ui.c.accentDim)
    scr:flush()
    broadcastState()
end

local function ignitionSequence()
    igniting = true
    page = "CORE"
    seqStage, seqInfo = "closeout", nil
    logEvent("IGNITION SEQUENCE INITIATED", ui.c.caution)

    -- STAGE 0: REACTOR COMPARTMENT CLOSE OUT -------------------
    local closeout = {
        { file = "closeout_10_voice", label = "CLOSE OUT IN 10 MINUTES", gap = 20 },
        { file = "closeout_5_voice",  label = "CLOSE OUT IN 5 MINUTES",  gap = 16 },
        { file = "closeout_2_voice",  label = "CLOSE OUT IN 2 MINUTES",  gap = 12 },
        { file = "closeout_1_voice",  label = "CLOSE OUT IN 1 MINUTE",   gap = 12 },
    }
    pa("prestart", true)
    local skipped = false
    for _, step in ipairs(closeout) do
        pa(step.file)
        seqInfo = step.label
        logEvent("RX COMPT " .. step.label, ui.c.caution)
        local deadline = os.clock() + step.gap
        while os.clock() < deadline and not skipped do
            tick = tick + 1
            scr:beginFrame()
            local midY = math.floor(H / 2)
            scr:center(1, W, midY - 4, "REACTOR COMPARTMENT CLOSE OUT", ui.c.warn)
            scr:center(1, W, midY - 1, step.label, ui.c.text)
            scr:center(1, W, midY + 5, "EYES ON CENTER DISPLAY", ui.c.accentDim)
            scr:button(math.floor(W / 2) - 9, H - 4, math.floor(W / 2) + 9, H - 3,
                "SKIP CLOSE OUT", ui.c.line, "skipCloseout", true)
            scr:flush()
            broadcastState()
            local tm = os.startTimer(0.25)
            while true do
                local ev, a, b, c = os.pullEvent()
                if ev == "timer" and a == tm then break end
                if ev == "monitor_touch" and a == scr.name
                    and scr:hitTest(b, c) == "skipCloseout" then
                    skipped = true
                    break
                end
            end
        end
        if skipped then break end
    end
    pa("closeout_set_voice", skipped)
    logEvent("CONTAINMENT SET", ui.c.ok)
    for _ = 1, 8 do
        seqScreen("REACTOR COMPARTMENT CLOSED",
            "PRIMARY AND SECONDARY CONTAINMENT SET")
        sleep(0.4)
    end

    -- STAGE 1: PRE-START CHECKS -------------------------------
    seqStage, seqInfo = "checks", nil
    pa("prestart")
    pa("prestart_voice")
    local checks = {
        "RX WATER INVENTORY", "D-T FUEL AVAILABLE", "HOHLRAUM LOADED",
        "TURBINE LINEUP", "CONDENSATE RETURN", "LASER BANKS STANDBY",
        "CONTAINMENT FIELD", "MATRIX LOAD PATH",
    }
    for i = 1, #checks do
        seqScreen("PRE-START CHECKS", checks[i] .. "  [ SAT ]")
        ui.beep(6 + (i % 4) * 2)
        sleep(0.9)
    end
    sleep(0.8)

    -- STAGE 2: LASER BANK CHARGE ------------------------------
    seqStage, seqInfo = "charging", nil
    pa("charging")
    pa("charging_voice")
    logEvent("LASER BANKS CHARGING", ui.c.caution)
    for bank = 1, 4 do
        seqInfo = string.char(64 + bank)
        ui.sound("block.conduit.activate", 0.8, 0.6 + bank * 0.15)
        for step = 1, 12 do
            DATA.lasers[bank] = step / 12
            seqScreen("CHARGING LASER BANK " .. string.char(64 + bank),
                math.floor(step / 12 * 100) .. "%")
            ui.beep(2 + step + bank)
            sleep(0.22)
        end
        ui.sound("block.note_block.chime", 1, 1.4 + bank * 0.15)
    end
    ui.sound("block.beacon.power_select", 1, 1)
    sleep(0.5)

    -- STAGE 3: FOCUS MATRIX ALIGNMENT -------------------------
    seqStage, seqInfo = "alignment", nil
    pa("alignment")
    pa("alignment_voice")
    for step = 1, 10 do
        seqScreen("FOCUS MATRIX ALIGNMENT",
            step >= 10 and "TARGET LOCK" or nil)
        ui.sound("block.note_block.hat", 0.7, 0.8 + step * 0.1)
        sleep(0.8)
    end
    ui.sound("block.beacon.power_select", 1, 1.4)
    sleep(0.6)

    -- STAGE 4: D-T INJECTOR PRE-PRESSURIZATION ----------------
    seqStage, seqInfo = "injection", nil
    pa("injection")
    pa("injection_voice")
    DATA.valves.fvd.demand = 100
    DATA.valves.fvt.demand = 100
    DATA.valves.fcv.demand = 100
    logEvent("FUEL VALVE LINEUP - OPENING", ui.c.caution)
    for step = 1, 8 do
        valveTick()
        seqScreen("D-T INJECTOR PRE-PRESSURIZATION",
            ("FV-D %d%%  FV-T %d%%  FCV %d%%"):format(
                DATA.valves.fvd.pos, DATA.valves.fvt.pos, DATA.valves.fcv.pos))
        if step % 2 == 1 then
            ui.sound("block.lava.extinguish", 0.6, 0.5 + step * 0.05)
        end
        sleep(1.2)
    end
    for _, v in pairs(DATA.valves) do v.pos = v.demand end
    valveTick()
    logEvent("FUEL VALVES OPEN - FCV 100%", ui.c.ok)
    sleep(0.4)

    -- STAGE 5: FINAL COUNTDOWN + KLAXON ------------------------
    seqStage = "countdown"
    pa("countdown_voice", true)
    pa("countdown")
    logEvent("IGNITION COUNTDOWN", ui.c.warn)
    for n = 10, 1, -1 do
        seqInfo = n
        if n % 2 == 0 then ui.sound("event.raid.horn", 1, 0.85) end
        for _ = 1, 4 do
            seqScreen("IGNITION IN " .. n)
            sleep(0.28)
        end
        ui.beep(15)
    end

    -- STAGE 6: FIRE --------------------------------------------
    seqStage, seqInfo = "fire", nil
    broadcastState()
    pa("fire_voice", true)
    pa("fire")
    logEvent("LASERS FIRING", ui.c.alarm)
    ui.sound("event.raid.horn", 1, 1.2)
    for step = 1, 12 do
        if step % 3 == 1 then
            ui.sound("entity.guardian.attack", 0.9, 0.6 + step * 0.05)
        end
        seqScreen("LASERS FIRING")
        sleep(0.35)
    end

    -- STAGE 7: IGNITION ----------------------------------------
    seqStage = "ignition"
    broadcastState()
    ui.sound("entity.lightning_bolt.thunder", 1, 1)
    ui.sound("entity.generic.explode", 1, 0.6)
    ui.sound("entity.ender_dragon.growl", 1, 0.7)
    DATA.ignited = true
    for _ = 1, 10 do
        seqScreen("** IGNITION **")
        sleep(0.14)
    end
    ui.sound("block.end_portal.spawn", 1, 1)

    -- STAGE 8: STABILIZATION / POWER ASCENSION -----------------
    seqStage = "stable"
    broadcastState()
    pa("confirmed", true)
    pa("confirmed_voice")
    for _ = 1, 10 do
        readData()
        seqScreen("PLASMA STABLE - POWER ASCENSION")
        sleep(1.2)
    end
    ui.sound("block.beacon.activate", 1, 1)
    pa("ascension_voice")
    paAmbient("engine_room")
    logEvent("REACTOR IGNITED - MODE 1", ui.c.ok)
    seqStage, seqInfo = nil, nil
    igniting = false
end

local function scram()
    scramAt = os.clock()
    if not DATA.rxLive then
        DATA.ignited = false -- sim only: real state comes from telemetry
    end
    DATA.valves.fvd.demand = 0
    DATA.valves.fvt.demand = 0
    DATA.valves.fcv.demand = 0
    raiseAlarm("SCRAM", "REACTOR SCRAM", "alarm")
    paAmbient(nil)
    pa("scram_voice", true)
    ui.sound("event.raid.horn", 1, 0.7)
    ui.sound("block.beacon.deactivate", 1, 0.8)
    ui.sound("block.fire.extinguish", 1, 0.7)
end

---------------------------------------------------------------
-- ACTION DISPATCH (touch + remote console commands)
---------------------------------------------------------------
local function handleAction(action)
    if not action then return end
    if action:sub(1, 5) == "page:" then
        page = action:sub(6)
        local want = (page == "SETUP" or page == "ALARMS") and 1
            or CONFIG.scale
        if scr.curScale ~= want then
            scr = ui.attach(scr.name, want)
            scr.curScale = want
            layout()
        end
        ui.beep(10)
    elseif action:sub(1, 3) == "tb:" then
        local i = tonumber(action:sub(4))
        if DATA.turbines[i] then
            DATA.turbines[i].online = not DATA.turbines[i].online
            logEvent("TB-" .. i .. (DATA.turbines[i].online
                and " RESTORED" or " ISOLATED"),
                DATA.turbines[i].online and ui.c.okDim or ui.c.warn)
            ui.beep(DATA.turbines[i].online and 12 or 6)
        end
    elseif action == "ignite" and not DATA.ignited and not igniting then
        ignitionSequence()
    elseif action == "scram" and DATA.ignited then
        scram()
    elseif action == "ack" then
        ackAll()
    elseif action == "fvd" or action == "fvt" then
        local v = DATA.valves[action]
        v.demand = (v.demand > 50) and 0 or 100
        saveValves()
        logEvent(action:upper() .. (v.demand > 50 and " OPENING" or " CLOSING"),
            v.demand > 50 and ui.c.okDim or ui.c.warn)
        ui.beep(v.demand > 50 and 12 or 6)
    elseif action == "mode1" then
        DATA.valves.fvd.demand = 100
        DATA.valves.fvt.demand = 100
        DATA.valves.fcv.demand = 200 / 49 -- two steps = 4 mB/t
        saveValves()
        logEvent("MODE 1 LINEUP - FUEL VALVES OPEN, MIN SUSTAINING", ui.c.caution)
        ui.sound("block.note_block.pling", 1, 1.2)
    elseif action == "battleshort" then
        DATA.battleshort = not DATA.battleshort
        logEvent(DATA.battleshort and "** BATTLESHORT SET - PROTECTION BYPASSED **"
            or "BATTLESHORT CLEARED - PROTECTION RESTORED",
            DATA.battleshort and ui.c.alarm or ui.c.ok)
        ui.sound(DATA.battleshort and "block.note_block.didgeridoo"
            or "block.note_block.bell", 1, 0.6)
    elseif action == "fcvUp" or action == "injUp" then
        -- one throttle step = one injection step = 2 mB/t (49 steps to 98)
        DATA.valves.fcv.demand = clamp(DATA.valves.fcv.demand + 100 / 49, 0, 100)
        saveValves()
        ui.beep(12)
    elseif action == "fcvDown" or action == "injDown" then
        DATA.valves.fcv.demand = clamp(DATA.valves.fcv.demand - 100 / 49, 0, 100)
        saveValves()
        ui.beep(8)
    end
end

---------------------------------------------------------------
-- MAIN
---------------------------------------------------------------
scr:boot("FUSION FACILITY", "UNIT 1 OPERATOR CONSOLE", {
    "Palette", "Core renderer", "Parameter engine", "Alarm engine",
    "Turbine interface", "Touch input", "Speaker link",
})
math.randomseed(os.epoch("utc"))
logEvent("CONSOLE ONLINE", ui.c.dim)
render()
local timer = os.startTimer(0.2)

while true do
    local event, side, x, y = os.pullEvent()
    if event == "timer" and side == timer then
        tick = tick + 1
        if tick % 2 == 0 then flash = not flash end
        if paReady and tick % 25 == 0 then
            rednet.broadcast({ type = "list" }, PA_PROTO) -- PA presence probe
        end
        if tick % 5 == 0 then nodeWatch() end
        readData()
        render()
        timer = os.startTimer(0.2)
    elseif event == "rednet_message" and y == "scada_hello" then
        if type(x) == "table" and x.role then
            roster[x.role] = os.clock()
            if not knownNodes[x.role] then
                knownNodes[x.role] = true
                saveKnown()
                logEvent(x.role .. " REGISTERED", ui.c.accentDim)
            end
        end
    elseif event == "rednet_message" and y == "scada_sensor" then
        if type(x) == "table" and x.type == "telemetry" and x.node then
            telemetry[x.node] = { t = os.clock(), turbine = x.turbine,
                tank = x.tank, readings = x.readings }
        end
    elseif event == "rednet_message" and y == "scada_mgmt" then
        if type(x) == "table" then
            if x.type == "reboot" and (x.target == "ALL"
                or x.target == "MASTER") then
                logEvent("REMOTE REBOOT COMMAND", ui.c.warn)
                sleep(0.5)
                os.reboot()
            elseif x.type == "ping" then
                local v = "?"
                if fs.exists("plant_version") then
                    local f = fs.open("plant_version", "r")
                    v = f.readAll()
                    f.close()
                end
                rednet.send(side, { type = "pong", role = "MASTER",
                    version = v }, "scada_mgmt")
            end
        end
    elseif event == "rednet_message" and y == "scada_pa" then
        if type(x) == "table" and x.type == "sounds" then
            paInfo.n = #(x.names or {})
            paInfo.t = os.clock()
        end
    elseif event == "monitor_touch" and side == scr.name then
        local action = scr:hitTest(x, y)
        if action then
            handleAction(action)
            render()
            timer = os.startTimer(0.2) -- sequences eat pending timers; restart
        end
    elseif event == "rednet_message" and y == "scada_cmd" then
        if type(x) == "table" and x.type == "cmd" then
            handleAction(x.action)
            render()
            timer = os.startTimer(0.2)
        end
    elseif event == "monitor_resize" and side == scr.name then
        scr = ui.attach(scr.name, CONFIG.scale)
        layout()
        render()
    end
end
