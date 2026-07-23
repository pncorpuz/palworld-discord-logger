-- Loads config.json (flat JSON: poll interval, Discord webhook settings).
--
-- Uses a path relative to the game process's working directory, not
-- require()'s module path -- io.open doesn't use package.path. Confirmed via
-- UE4SS.log at startup ("working directory: ...\Pal\Binaries\Win64") that the
-- process cwd is the Win64 folder, so this path is anchored from there.

local SimpleJson = require("SimpleJson")

local CONFIG_PATH = "ue4ss/Mods/BaseInventoryLogger/Scripts/config.json"

local DEFAULTS = {
    poll_interval_seconds = 10,
    discord_enabled = false,
    discord_webhook_url = "",
}

local function LoadConfig()
    local config = {}
    for k, v in pairs(DEFAULTS) do config[k] = v end

    local file = io.open(CONFIG_PATH, "r")
    if not file then
        print(string.format("[BaseInventoryLogger] config.json not found at %s, using defaults\n", CONFIG_PATH))
        return config
    end

    local text = file:read("*a")
    file:close()

    local ok, parsed = pcall(SimpleJson.DecodeFlat, text)
    if not ok then
        print("[BaseInventoryLogger] config.json failed to parse, using defaults\n")
        return config
    end

    for k in pairs(DEFAULTS) do
        if parsed[k] ~= nil then config[k] = parsed[k] end
    end

    return config
end

return LoadConfig()
