--[[
sensor_node.lua -- plant telemetry node (v3, turbine-grade)
One computer per instrumented location. This node:
  - opens EVERY attached modem (wired + wireless/ender) so telemetry
    always reaches the control room regardless of which network is which
  - heartbeats as NODE_<name> on "scada_hello" (SETUP roster + LOI)
  - broadcasts on "scada_sensor" twice a second:
      * a distilled TURBINE summary if a turbine valve is reachable
      * a distilled TANK summary if a dynamic tank valve is reachable
      * raw readings from everything else it can see
  - survives unformed multiblocks, missing peripherals, and chunk
    weirdness without crashing (everything is pcall-guarded)

Identity: file "role" on this computer (written by install.lua),
falling back to CONFIG.NODE. Turbine nodes must be TB1, TB2, ...
so the master maps them to MTG-1, MTG-2.
]]

local CONFIG = {
    NODE = "TB1",
    PERIOD = 0.5,
}

if fs.exists("role") then
    local f = fs.open("role", "r")
    CONFIG.NODE = f.readAll():gsub("%s+", "")
    f.close()
end

---------------------------------------------------------------
-- open every modem we have
---------------------------------------------------------------
local opened = 0
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
        if not rednet.isOpen(name) then rednet.open(name) end
        opened = opened + 1
    end
end
if opened == 0 then
    error("Sensor node needs at least one modem (wired or ender)", 0)
end

---------------------------------------------------------------
-- readers
---------------------------------------------------------------
local function tryCall(p, method)
    if type(p[method]) ~= "function" then return nil end
    local ok, v = pcall(p[method])
    if ok then return v end
    return nil
end

-- distilled turbine summary from a turbine valve
local function readTurbine(p)
    local t = {
        flow      = tryCall(p, "getFlowRate"),
        lastInput = tryCall(p, "getLastSteamInputRate"),
        maxFlow   = tryCall(p, "getMaxFlowRate"),
        prod      = tryCall(p, "getProductionRate"),
        maxProd   = tryCall(p, "getMaxProduction"),
        steamPct  = tryCall(p, "getSteamFilledPercentage"),
        energyPct = tryCall(p, "getEnergyFilledPercentage"),
        dump      = tryCall(p, "getDumpingMode"),
        blades    = tryCall(p, "getBlades"),
        vents     = tryCall(p, "getVents"),
        condensers = tryCall(p, "getCondensers"),
        maxWaterOut = tryCall(p, "getMaxWaterOutput"),
    }
    t.formed = (t.flow ~= nil or t.steamPct ~= nil)
    if type(t.dump) == "table" then t.dump = tostring(t.dump[1] or "?") end
    return t
end

-- distilled tank summary from a dynamic tank valve (hot well etc.)
local function readTank(p)
    local pct = tryCall(p, "getFilledPercentage")
    local stored = tryCall(p, "getStored")
    local cap = tryCall(p, "getTankCapacity") or tryCall(p, "getCapacity")
    if pct == nil and stored == nil then return nil end
    local t = { pct = pct, capacity = cap }
    if type(stored) == "table" then
        t.content = stored.name
        t.amount = stored.amount
    end
    return t
end

local GENERIC_TRY = {
    "getPlasmaTemperature", "getCaseTemperature", "isIgnited",
    "getInjectionRate", "getProductionRate", "getPassiveGeneration",
    "getWaterFilledPercentage", "getSteamFilledPercentage",
    "getDeuteriumFilledPercentage", "getTritiumFilledPercentage",
    "getDTFuelFilledPercentage", "getEnergyFilledPercentage",
    "getFilledPercentage", "getEnergy", "getMaxEnergy",
    "getLastInput", "getLastOutput",
}

local function collect()
    local packet = { type = "telemetry", node = CONFIG.NODE, readings = {} }
    for _, name in ipairs(peripheral.getNames()) do
        local ty = peripheral.getType(name)
        if ty ~= "modem" then
            local p = peripheral.wrap(name)
            if p then
                local tyl = tostring(ty):lower()
                if tyl:find("turbine") and not packet.turbine then
                    packet.turbine = readTurbine(p)
                    packet.turbine.via = name
                elseif tyl:find("dynamic") or tyl:find("tank") then
                    local tk = readTank(p)
                    if tk then
                        packet.tanks = packet.tanks or {}
                        packet.tanks[name] = tk
                        if not packet.tank then
                            packet.tank = tk        -- first tank = hot well
                            packet.tank.via = name  -- (TB-node convention)
                        end
                    end
                else
                    local entry = { type = ty }
                    local got = false
                    for _, m in ipairs(GENERIC_TRY) do
                        local v = tryCall(p, m)
                        if v ~= nil and (type(v) == "number"
                            or type(v) == "boolean" or type(v) == "string") then
                            entry[m] = v
                            got = true
                        end
                    end
                    if got then
                        packet.readings[name] = entry
                    else
                        -- connected but unreadable: report it loudly so a
                        -- wrong-block binding is diagnosed, not silent
                        packet.unreadable = packet.unreadable or {}
                        packet.unreadable[name] = ty
                    end
                end
            end
        end
    end
    return packet
end

---------------------------------------------------------------
-- main
---------------------------------------------------------------
print(("Sensor node NODE_%s online (%d modem(s) open)."):format(
    CONFIG.NODE, opened))
print("Broadcasting every " .. CONFIG.PERIOD .. "s. Ctrl+T to stop.")

local n = 0
local nextCast = 0
while true do
    if os.clock() >= nextCast then
        n = n + 1
        if n % 8 == 1 then
            rednet.broadcast({ type = "hello", role = "NODE_" .. CONFIG.NODE },
                "scada_hello")
        end
        local ok, packet = pcall(collect)
        if ok then
            rednet.broadcast(packet, "scada_sensor")
            if n % 20 == 0 then
                local bits = {}
                if packet.turbine then
                    bits[#bits + 1] = packet.turbine.formed
                        and ("turbine OK flow=" .. tostring(
                            packet.turbine.lastInput or packet.turbine.flow or 0))
                        or "turbine UNFORMED"
                end
                if packet.tanks then
                    local c = 0
                    for _ in pairs(packet.tanks) do c = c + 1 end
                    bits[#bits + 1] = c .. " tank(s)"
                end
                local c = 0
                for _ in pairs(packet.readings) do c = c + 1 end
                if c > 0 then bits[#bits + 1] = c .. " other" end
                if packet.unreadable then
                    for nm, ty in pairs(packet.unreadable) do
                        print(("!! %s [%s] connected but NO readable values"):format(
                            nm, ty))
                        local ms = peripheral.getMethods(nm) or {}
                        table.sort(ms)
                        print("   methods: " .. table.concat(ms, ", "):sub(1, 200))
                        if tostring(ty):lower():find("controller") then
                            print("   >> controllers may not expose data - move the")
                            print("   >> wired modem to a REACTOR PORT instead")
                        end
                    end
                end
                print(("[%s] %s"):format(os.date("%H:%M:%S"),
                    #bits > 0 and table.concat(bits, ", ")
                    or "no readable peripherals"))
            end
        end
        nextCast = os.clock() + CONFIG.PERIOD
    end
    -- wait for the next broadcast slot, servicing actuation commands
    local timer = os.startTimer(math.max(0.05, nextCast - os.clock()))
    while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "timer" and a == timer then break end
        if ev == "rednet_message" and c == "scada_actuate"
            and type(b) == "table" and b.target == CONFIG.NODE
            and b.set == "injection" and type(b.value) == "number" then
            local done = false
            for _, name in ipairs(peripheral.getNames()) do
                local p = peripheral.wrap(name)
                if p and type(p.setInjectionRate) == "function" then
                    local okc, err = pcall(p.setInjectionRate, b.value)
                    print(("[%s] setInjectionRate(%d) %s"):format(
                        os.date("%H:%M:%S"), b.value,
                        okc and "OK" or ("FAILED: " .. tostring(err))))
                    done = true
                    break
                end
            end
            if not done then
                print("actuate: no peripheral with setInjectionRate here")
            end
            break
        end
    end
end
