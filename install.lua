--[[
install.lua -- one-command bootstrap for any plant computer
On a fresh computer, run:

  wget run https://raw.githubusercontent.com/NikeGoPro/fusion-plant/main/install.lua <role> [sub]

Roles:
  hmi | primary | oneline | viewer | pa
  console RPCP     (or: console SPCP)
  sensor TB1       (or: sensor REACTOR / TB2 / TANKS / FUEL ...)

Writes the role file + startup.lua, fetches updater.lua, then runs the
updater which downloads this role's programs and reboots.
]]

local BASE = "https://raw.githubusercontent.com/NikeGoPro/fusion-plant/main/"
local PROG = {
    hmi = "hmi.lua", primary = "primary.lua", oneline = "oneline.lua",
    viewer = "viewer.lua", console = "console.lua", pa = "pa.lua",
    sensor = "sensor_node.lua", laser = "laser_node.lua",
    admin = "admin.lua",
}

local args = { ... }
local role, sub = args[1], args[2]
if not role or not PROG[role] then
    print("usage: install <hmi|primary|oneline|viewer|console|pa|sensor|laser|admin> [sub]")
    print("  console needs RPCP or SPCP; sensor needs a node name (TB1...)")
    return
end
if role == "console" and not sub then
    print("console needs RPCP or SPCP as second argument")
    return
end
if role == "sensor" and not sub then
    print("sensor needs a node name (REACTOR, TB1, TB2, TANKS, FUEL...)")
    return
end

if sub then
    local f = fs.open("role", "w")
    f.write(sub)
    f.close()
    print("role file: " .. sub)
end

local r = http.get(BASE .. "updater.lua")
if not r then error("cannot reach repo - check http config", 0) end
local f = fs.open("updater.lua", "w")
f.write(r.readAll())
f.close()
r.close()

f = fs.open("startup.lua", "w")
f.write(('shell.run("updater.lua", %q)\nshell.run(%q)\n'):format(
    role, PROG[role]))
f.close()

print("installed as " .. role .. (sub and (" (" .. sub .. ")") or ""))
print("fetching programs...")
shell.run("updater.lua", role)
-- updater reboots on success; if we're still here, run directly
shell.run(PROG[role])
