-- Loads config.json (poll interval, Discord enable flag, per-guild webhooks).
-- LINUX BUILD (ue4ss-linux / XarminaEu) -- adapted from the Windows version.
--
-- guild_webhooks maps guild name -> webhook URL, plus one reserved key
-- "all" for an admin webhook that gets a combined report across every
-- guild. A guild with no matching entry (and no "all" configured) just
-- never gets a Discord post -- console logging is unaffected either way.
--
-- Uses a path relative to the game process's working directory, not
-- require()'s module path -- io.open doesn't use package.path. On the
-- Windows build, UE4SS.log confirmed the cwd is the Win64 folder itself
-- (no nested Mods subfolder prefix beyond "ue4ss/"). ue4ss-linux's install
-- layout has no "ue4ss/" subfolder at all -- libUE4SS.so and Mods/ sit
-- directly in Binaries/Linux/ -- so this tries that path first, with the
-- Windows-style path kept as a fallback in case the assumption about cwd
-- is wrong here. UNVERIFIED on this Linux port -- check UE4SS.log's own
-- reported "working directory" if config loading fails and adjust.
local CONFIG_PATH_CANDIDATES = {
    "Mods/BaseInventoryLogger/scripts/config.json",
    "ue4ss/Mods/BaseInventoryLogger/scripts/config.json",
}

local SimpleJson = require("SimpleJson")

local DEFAULTS = {
    poll_interval_seconds = 10,
    discord_enabled = false,
}

local function OpenConfigFile()
    for _, path in ipairs(CONFIG_PATH_CANDIDATES) do
        local file = io.open(path, "r")
        if file then return file, path end
    end
    return nil, nil
end

local function LoadConfig()
    local config = {}
    for k, v in pairs(DEFAULTS) do config[k] = v end
    config.guild_webhooks = {}

    local file, usedPath = OpenConfigFile()
    if not file then
        print(string.format("[BaseInventoryLogger] config.json not found (tried: %s), using defaults\n",
            table.concat(CONFIG_PATH_CANDIDATES, ", ")))
        return config
    end
    print(string.format("[BaseInventoryLogger] Loaded config from %s\n", usedPath))

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
