-- fleet manifest: bump version, push, reboot the fleet.
-- verify[] markers: a string that MUST exist in the current file;
-- protects against stale CDN copies being installed as "updated".
return {
    version = 13,
    files = {
        ["updater.lua"] = "updater.lua",
        ["ui.lua"] = "ui.lua",
        ["hmi.lua"] = "hmi.lua",
        ["console.lua"] = "console.lua",
        ["viewer.lua"] = "viewer.lua",
        ["oneline.lua"] = "oneline.lua",
        ["primary.lua"] = "primary.lua",
        ["pa.lua"] = "pa.lua",
        ["sensor_node.lua"] = "sensor_node.lua",
    },
    verify = {
        ["updater.lua"] = "fleet auto-update v2",
        ["ui.lua"] = "loiBox",
        ["hmi.lua"] = "TELEM_FRESH",
        ["console.lua"] = "per-computer role",
        ["viewer.lua"] = "STEAM PLANT DISPLAY WALL",
        ["oneline.lua"] = "LIVE",
        ["primary.lua"] = "renderIgnition",
        ["pa.lua"] = "AMBIENT_VOLUME",
        ["sensor_node.lua"] = "turbine-grade",
    },
}
