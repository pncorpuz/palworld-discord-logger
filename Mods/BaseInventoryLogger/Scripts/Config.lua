-- Loads config.json (poll interval, Discord enable flag, per-guild webhooks).
--
-- guild_webhooks maps guild name -> webhook URL, plus one reserved key
-- "all" for an admin webhook that gets a combined report across every
-- guild. A guild with no matching entry (and no "all" configured) just
-- never gets a Discord post -- console logging is unaffected either way.
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
}

local function LoadConfig()
    local config = {}
    for k, v in pairs(DEFAULTS) do config[k] = v end
    config.guild_webhooks = {}

    local file = io.open(CONFIG_PATH, "r")
    if not file then
        print(string.format("[BaseInventoryLogger] config.json not found at %s, using defaults\n", CONFIG_PATH))
        return config
    end

    local text = file:read("*a")
    file:close()

    local ok, parsed = pcall(SimpleJson.DecodeFlat, text)
    if ok then
        for k in pairs(DEFAULTS) do
            if parsed[k] ~= nil then config[k] = parsed[k] end
        end
    else
        print("[BaseInventoryLogger] config.json failed to parse top-level fields, using defaults\n")
    end

    local okObj, webhooksText = pcall(SimpleJson.ExtractObject, text, "guild_webhooks")
    if okObj and webhooksText then
        local okDecode, decoded = pcall(SimpleJson.DecodeFlat, webhooksText)
        if okDecode then
            -- Lua treats "" as truthy (only nil/false are falsy), so an
            -- empty string left as-is would still read as "configured".
            -- Drop empty entries here so downstream code can just check
            -- `config.guild_webhooks[name]` for nil.
            for k, v in pairs(decoded) do
                if v ~= "" then config.guild_webhooks[k] = v end
            end
        else
            print("[BaseInventoryLogger] config.json guild_webhooks failed to parse\n")
        end
    end

    return config
end

return LoadConfig()
