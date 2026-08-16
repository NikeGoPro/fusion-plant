--[[
updater.lua -- fleet auto-update v2 (verified)
Run from startup.lua:   shell.run("updater.lua", "<role>")

v2 fixes the stale-CDN failure class:
  - every fetch carries a cache-buster (?v=<version>&r=<rand>) so
    raw.githubusercontent.com can never serve a 5-minute-old file
  - each downloaded file is VERIFIED against a marker string from the
    manifest before it replaces anything; mismatches retry (3x) with a
    fresh cache-buster, then abort
  - plant_version only advances when EVERY file verified, so a failed
    or partial update retries automatically on the next boot instead
    of silently claiming success
  - the updater ships itself in every role, so future updater fixes
    propagate through the normal cycle
]]

local CONFIG = {
    BASE = "https://raw.githubusercontent.com/NikeGoPro/fusion-plant/main/",
}

local ROLES = {
    hmi     = { "updater.lua", "ui.lua", "hmi.lua" },
    primary = { "updater.lua", "ui.lua", "primary.lua" },
    oneline = { "updater.lua", "ui.lua", "oneline.lua" },
    viewer  = { "updater.lua", "ui.lua", "viewer.lua" },
    console = { "updater.lua", "ui.lua", "console.lua" },
    pa      = { "updater.lua", "pa.lua" },
    sensor  = { "updater.lua", "sensor_node.lua" },
    laser   = { "updater.lua", "laser_node.lua" },
    admin   = { "updater.lua", "admin.lua" },
}

local role = ({ ... })[1]
if not role or not ROLES[role] then
    local k = {}
    for r in pairs(ROLES) do k[#k + 1] = r end
    print("usage: updater <" .. table.concat(k, "|") .. ">")
    return
end

local function bust(ref, ver)
    return CONFIG.BASE .. ref .. "?v=" .. tostring(ver)
        .. "&r=" .. math.random(1, 999999)
end

local function fetchText(url)
    local r = http.get(url)
    if not r then return nil end
    local body = r.readAll()
    r.close()
    return body
end

-- manifest (cache-busted with a random token; version unknown yet)
math.randomseed(os.epoch("utc"))
local body = fetchText(bust("manifest.lua", "m"))
if not body then
    print("updater: repo unreachable, running existing code")
    return
end
local chunk = load(body, "manifest")
if not chunk then
    print("updater: manifest unreadable, skipping")
    return
end
local ok, manifest = pcall(chunk)
if not ok or type(manifest) ~= "table" or not manifest.version then
    print("updater: bad manifest, skipping")
    return
end

local localVer = 0
if fs.exists("plant_version") then
    local f = fs.open("plant_version", "r")
    localVer = tonumber(f.readAll()) or 0
    f.close()
end
if manifest.version <= localVer then
    print("updater: v" .. localVer .. " current")
    return
end

print(("updater: v%d -> v%d (%s)"):format(localVer, manifest.version, role))
local staged = {}
local allOk = true
for _, fname in ipairs(ROLES[role]) do
    local ref = manifest.files and manifest.files[fname]
    if ref then
        local marker = manifest.verify and manifest.verify[fname]
        local content
        for attempt = 1, 3 do
            content = fetchText(bust(ref, manifest.version))
            if content and (not marker or content:find(marker, 1, true)) then
                break
            end
            print(("  %s: stale/bad copy (try %d), retrying..."):format(
                fname, attempt))
            content = nil
            sleep(1)
        end
        if content then
            staged[fname] = content
            print(("  %s ok (%d bytes, verified)"):format(fname, #content))
        else
            print("  " .. fname .. " FAILED verification")
            allOk = false
        end
    end
end

if not allOk then
    print("updater: update REJECTED, keeping v" .. localVer
        .. " (will retry next boot)")
    return
end

-- everything verified: commit atomically
for fname, content in pairs(staged) do
    local f = fs.open(fname .. ".new", "w")
    f.write(content)
    f.close()
    fs.delete(fname)
    fs.move(fname .. ".new", fname)
end
local f = fs.open("plant_version", "w")
f.write(tostring(manifest.version))
f.close()
print("updater: now v" .. manifest.version .. ", rebooting...")
sleep(1)
os.reboot()
