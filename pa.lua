--[[
pa.lua -- Plant PA system / audio server node
Runs on a dedicated computer with one or more Speakers attached
(directly or via wired modems around the plant) plus a wireless/ender
modem for rednet.

Plays DFPWM audio files from the /sounds directory on request.

Getting sounds onto this computer:
  1. Convert any MP3/WAV at https://music.madefor.cc (or:
     ffmpeg -i in.mp3 -ar 48000 -ac 1 out.dfpwm)
  2. Host the file with a direct-download link
  3. In this computer's shell:  wget <url> sounds/scram.dfpwm

Triggering from any other computer (e.g. the HMI):
  rednet.open("<modem side>")
  rednet.broadcast({ type = "play", name = "scram" }, "scada_pa")
Other messages: { type = "stop" }, { type = "list" }

Local testing from this computer's shell:
  pa list
  pa play scram
]]

local CONFIG = {
    PROTOCOL  = "scada_pa",
    SOUND_DIR = "sounds",
    VOLUME    = 1.5,      -- 0..3, announcements/SFX
    AMBIENT_VOLUME = 0.45, -- background loop plays quieter
    CHUNK     = 16 * 1024,
}

local dfpwm = require("cc.audio.dfpwm")

---------------------------------------------------------------
-- SETUP
---------------------------------------------------------------
local speakers = { peripheral.find("speaker") }
if #speakers == 0 then error("No speakers attached", 0) end

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
            or peripheral.find("modem")
if modem then rednet.open(peripheral.getName(modem)) end

if not fs.exists(CONFIG.SOUND_DIR) then fs.makeDir(CONFIG.SOUND_DIR) end

local function soundPath(name)
    local p = fs.combine(CONFIG.SOUND_DIR, name .. ".dfpwm")
    if fs.exists(p) then return p end
end

local function listSounds()
    local names = {}
    for _, f in ipairs(fs.list(CONFIG.SOUND_DIR)) do
        if f:sub(-6) == ".dfpwm" then names[#names + 1] = f:sub(1, -7) end
    end
    return names
end

---------------------------------------------------------------
-- PLAYBACK
---------------------------------------------------------------
local stopRequested = false

local function playToAll(buffer, vol)
    local pending = {}
    for _, s in ipairs(speakers) do pending[s] = true end
    while true do
        local done = true
        for s in pairs(pending) do
            if s.playAudio(buffer, vol or CONFIG.VOLUME) then
                pending[s] = nil
            else
                done = false
            end
        end
        if done then return end
        os.pullEvent("speaker_audio_empty")
    end
end

local function stopAll()
    for _, s in ipairs(speakers) do pcall(s.stop) end
end

local function playFile(name, vol)
    local path = soundPath(name)
    if not path then
        print("Unknown sound: " .. name)
        return false
    end
    stopRequested = false
    local decoder = dfpwm.make_decoder()
    for chunk in io.lines(path, CONFIG.CHUNK) do
        if stopRequested then break end
        playToAll(decoder(chunk), vol)
    end
    if stopRequested then stopAll() end
    return true
end

---------------------------------------------------------------
-- QUEUE + SERVER LOOPS
---------------------------------------------------------------
local queue = {}
local ambientName = nil   -- loops forever when set and queue is empty
local nowPlaying = nil    -- "announce" | "ambient" | nil

local function playerLoop()
    while true do
        if #queue > 0 then
            local name = table.remove(queue, 1)
            nowPlaying = "announce"
            print("PLAYING: " .. name)
            playFile(name, CONFIG.VOLUME)
            nowPlaying = nil
        elseif ambientName then
            nowPlaying = "ambient"
            playFile(ambientName, CONFIG.AMBIENT_VOLUME)
            nowPlaying = nil
        else
            sleep(0.1)
        end
    end
end

local function rednetLoop()
    while true do
        local sender, msg, proto = rednet.receive()
        if proto == "scada_mgmt" and type(msg) == "table" then
            if msg.type == "reboot" and (msg.target == "ALL"
                or msg.target == "PA") then
                sleep(0.5)
                os.reboot()
            elseif msg.type == "ping" then
                local v = "?"
                if fs.exists("plant_version") then
                    local f = fs.open("plant_version", "r")
                    v = f.readAll()
                    f.close()
                end
                rednet.send(sender, { type = "pong", role = "PA",
                    version = v }, "scada_mgmt")
            end
        end
        if proto ~= CONFIG.PROTOCOL then msg = nil end
        if type(msg) == "table" then
            if msg.type == "play" and type(msg.name) == "string" then
                if msg.interrupt then
                    stopRequested = true
                    queue = { msg.name }
                else
                    queue[#queue + 1] = msg.name
                    -- duck the ambient loop so the announcement starts now
                    if nowPlaying == "ambient" then stopRequested = true end
                end
            elseif msg.type == "sfx" and type(msg.name) == "string" then
                -- vanilla sound effect, all plant speakers at once
                for _, s in ipairs(speakers) do
                    pcall(s.playSound, msg.name, msg.vol or 1, msg.pitch or 1)
                end
            elseif msg.type == "ambient" then
                if type(msg.name) == "string" and soundPath(msg.name) then
                    ambientName = msg.name
                    print("AMBIENT: " .. msg.name)
                else
                    ambientName = nil
                    if nowPlaying == "ambient" then stopRequested = true end
                    print("AMBIENT: off")
                end
            elseif msg.type == "stop" then
                stopRequested = true
                queue = {}
                ambientName = nil
            elseif msg.type == "list" then
                rednet.send(sender, { type = "sounds", names = listSounds() },
                    CONFIG.PROTOCOL)
            end
        end
    end
end

---------------------------------------------------------------
-- MAIN (also supports shell usage: pa play <name> / pa list)
---------------------------------------------------------------
local args = { ... }
if args[1] == "play" and args[2] then
    playFile(args[2], CONFIG.VOLUME)
    return
elseif args[1] == "list" then
    print("Available sounds: " .. table.concat(listSounds(), ", "))
    return
end

print(("PA system online: %d speaker(s), protocol '%s'"):format(
    #speakers, CONFIG.PROTOCOL))
print("Sounds loaded: " .. (#listSounds() > 0
    and table.concat(listSounds(), ", ") or "(none yet - wget some!)"))
parallel.waitForAny(playerLoop, rednetLoop)
