--[[
sensor_node.lua -- plant telemetry node (v2)
One per data-collection computer. Attach peripherals (turbine valve,
reactor port / logic adapter, dynamic tank valve, induction port) via
wired modems, plus an ender/wireless modem (or the wired trunk) for
rednet back to the control room.

Set CONFIG.NODE to this node's identity. Suggested names:
  "REACTOR" - fusion reactor ports / logic adapter
  "TB1", "TB2" - one per turbine (its valve)
  "TANKS" - fuel train storage tanks
  "FUEL" - separators / SNA production instrumentation

The node:
  - announces itself on "scada_hello" as NODE_<name> (feeds the master's
    SETUP roster + LOI detection)
  - broadcasts raw readings from every attached peripheral on
    "scada_sensor" twice a second
Rename to startup.lua on the node computer.
]]

local CONFIG = {
    NODE = "TB1",
    PERIOD = 0.5,
}

local modem = peripheral.find("modem")
if not modem then error("Sensor node needs a modem", 0) end
rednet.open(peripheral.getName(modem))

-- methods worth trying on anything we find; pcall guards the rest
local TRY = {
    "getPlasmaTemperature", "getCaseTemperature", "isIgnited",
    "getInjectionRate", "getProductionRate", "getPassiveGeneration",
    "getWater", "getSteam", "getWaterFilledPercentage",
    "getSteamFilledPercentage", "getDeuterium", "getTritium", "getDTFuel",
    "getFlowRate", "getLastSteamInputRate", "getMaxFlowRate",
    "getProductionRate", "getEnergyFilledPercentage", "getDumpingMode",
    "getFilledPercentage", "getStored", "getCapacity",
    "getEnergy", "getMaxEnergy", "getLastInput", "getLastOutput",
}

local function readAll()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        if p then
            local entry = { type = peripheral.getType(name) }
            local got = false
            for _, m in ipairs(TRY) do
                if p[m] then
                    local ok, v = pcall(p[m])
                    if ok and (type(v) == "number" or type(v) == "boolean"
                        or type(v) == "string") then
                        entry[m] = v
                        got = true
                    end
                end
            end
            if got then out[name] = entry end
        end
    end
    return out
end

print(("Sensor node NODE_%s online. Broadcasting every %.1fs."):format(
    CONFIG.NODE, CONFIG.PERIOD))
local n = 0
while true do
    n = n + 1
    if n % 8 == 1 then
        rednet.broadcast({ type = "hello", role = "NODE_" .. CONFIG.NODE },
            "scada_hello")
    end
    local readings = readAll()
    rednet.broadcast({ type = "telemetry", node = CONFIG.NODE,
        readings = readings }, "scada_sensor")
    if n % 20 == 0 then
        local c = 0
        for _ in pairs(readings) do c = c + 1 end
        print(("[%s] %d peripheral(s) reporting"):format(
            os.date("%H:%M:%S"), c))
    end
    sleep(CONFIG.PERIOD)
end
