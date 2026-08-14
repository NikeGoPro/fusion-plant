--[[
updater.lua -- fleet auto-update for all plant computers
Run from each computer's startup.lua BEFORE the main program:

    shell.run("updater.lua", "hmi")     -- role name, see ROLES below
    shell.run("hmi.lua")

Two backends (set CONFIG.MODE):

  "github"  (RECOMMENDED): host the plant files in a public GitHub repo.
     CONFIG.BASE = raw URL prefix, e.g.
       "https://raw.githubusercontent.com/<you>/<repo>/main/"
     The repo root must contain manifest.lua plus every program file.
     Push a new commit = whole plant updates on next reboot.

  "pastebin": host a MANIFEST paste you EDIT in place (same code
     forever) so its content can point at new per-file paste codes.
     CONFIG.MANIFEST = that paste code. Each file is its own paste;
     when you update a file you make a new paste and edit the manifest
     to reference the new code.

manifest.lua content (same format for both backends):
  return {
    version = 3,
    files = {
      -- github MODE: value = path relative to BASE
      -- pastebin MODE: value = paste code
      ["ui.lua"] = "ui.lua",
      ["hmi.lua"] = "hmi.lua",
      ["console.lua"] = "console.lua",
      ["viewer.lua"] = "viewer.lua",
      ["oneline.lua"] = "oneline.lua",
      ["primary.lua"] = "primary.lua",
      ["pa.lua"] = "pa.lua",
      ["sensor_node.lua"] = "sensor_node.lua",
    },
  }

Local version is stored in /plant_version; if the manifest's version is
newer, this role's files are re-downloaded and the computer reboots.
]]

local CONFIG = {
    MODE = "github",
    BASE = "https://raw.githubusercontent.com/NikeGoPro/fusion-plant/main/",
    MANIFEST = "XXXXXXXX", -- pastebin mode only
}

-- which files each computer role needs
local ROLES = {
    hmi     = { "ui.lua", "hmi.lua" },
    primary = { "ui.lua", "primary.lua" },
    oneline = { "ui.lua", "oneline.lua" },
    viewer  = { "ui.lua", "viewer.lua" },
    console = { "ui.lua", "console.lua" },
    pa      = { "pa.lua" },
    sensor  = { "sensor_node.lua" },
}

local role = ({ ... })[1]
if not role or not ROLES[role] then
    print("usage: updater <" .. (function()
        local k = {}
        for r in pairs(ROLES) do k[#k + 1] = r end
        return table.concat(k, "|")
    end)() .. ">")
    return
end

local function fetch(ref, dest)
    if CONFIG.MODE == "pastebin" then
        fs.delete(dest .. ".new")
        local ok = shell.run("pastebin", "get", ref, dest .. ".new")
        if not ok or not fs.exists(dest .. ".new") then return false end
    else
        local r = http.get(CONFIG.BASE .. ref)
        if not r then return false end
        local f = fs.open(dest .. ".new", "w")
        f.write(r.readAll())
        f.close()
        r.close()
    end
    fs.delete(dest)
    fs.move(dest .. ".new", dest)
    return true
end

-- fetch manifest
local manifest
do
    local ref = (CONFIG.MODE == "pastebin") and CONFIG.MANIFEST or "manifest.lua"
    if not fetch(ref, ".manifest_tmp") then
        print("updater: no connection / manifest unavailable, skipping")
        return
    end
    local ok, m = pcall(dofile, ".manifest_tmp")
    fs.delete(".manifest_tmp")
    if not ok or type(m) ~= "table" or not m.version then
        print("updater: bad manifest, skipping")
        return
    end
    manifest = m
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

print(("updater: v%d -> v%d, updating %s files..."):format(
    localVer, manifest.version, role))
local allOk = true
for _, fname in ipairs(ROLES[role]) do
    local ref = manifest.files[fname]
    if ref then
        if fetch(ref, fname) then
            print("  updated " .. fname)
        else
            print("  FAILED " .. fname)
            allOk = false
        end
    end
end

if allOk then
    local f = fs.open("plant_version", "w")
    f.write(tostring(manifest.version))
    f.close()
    print("updater: now v" .. manifest.version .. ", rebooting...")
    sleep(1)
    os.reboot()
else
    print("updater: partial failure, version not bumped")
end
