-- BaseInventoryLogger: every 10s, logs Pals + status per base, grouped by guild.
--
-- Chain confirmed against CXXHeaderDump/Pal.hpp:
--   APalPlayerState.GuildBelongTo (UPalGroupGuildBase*) -- plain pointer property
--     .ID (FGuid, from UPalGroupBase)     -- group's own id
--     .GuildName (FString)                -- display name shown in the Guild UI
--   UPalBaseCampModel.GroupIdBelongTo (FGuid) -- matched against GuildBelongTo.ID above
--   UPalBaseCampModel.WorkerDirector (UPalBaseCampWorkerDirector)
--     .CharacterContainer (UPalIndividualCharacterContainer)
--       .Num() / .Get(index) -> UPalIndividualCharacterSlot
--         .Handle (UPalIndividualCharacterHandle) : TryGetIndividualParameter() -> UPalIndividualCharacterParameter
--           .SaveParameter (FPalIndividualCharacterSaveParameter) ->
--             CharacterID / NickName / Level / Hp / MaxHP (FFixedPoint64) /
--             FullStomach / MaxFullStomach (float) / SanityValue (float) /
--             PhysicalHealth (EPalStatusPhysicalHealthType) / WorkerSick (EPalBaseCampWorkerSickType) /
--             CurrentWorkSuitability (EPalWorkSuitability)
--
-- IMPORTANT: a non-nil Lua value from UE4SS is NOT the same as a valid object.
-- Empty slots etc. can come back as a wrapper around a null/freed native pointer,
-- which is still "truthy" in Lua. Touching properties/methods on one of those is
-- a native crash (EXCEPTION_ACCESS_VIOLATION), which pcall CANNOT catch, because
-- it's not a Lua-level error. Every hop below is gated on :IsValid(), not just nil.
--
-- API surprises found while building this mod:
--  1. UPalGroupManager:TryGetGuildName(GroupId) and other out-param UFUNCTIONs
--     (e.g. UPalUIUtility:GetUIDisplayPalCondition) proved unreliable to call
--     from Lua in this binding -- avoided in favor of plain properties, which
--     is what PhysicalHealth/WorkerSick/CurrentWorkSuitability are.
--  2. FGuid has no :ToString() in this binding. It's a plain struct with four
--     uint32 fields (A/B/C/D) -- read those directly instead.
--  3. HP is FFixedPoint64 (struct { int64 Value }), not a plain float/int.
--     Converted via UFixedPoint64MathLibrary's CDO (StaticFindObject), same
--     "Default__ClassName" pattern the guide uses for PalUtility.
--  4. Base display name (BaseCampName) comes back as unresolved localization/
--     format-string garbage ("?????????0(?)") -- using sequential "Base N"
--     numbering per guild instead.

local MAX_SLOTS_SAFETY_CAP = 200 -- belt-and-suspenders in case Num() is ever wrong

-- Discord embed field.value hard limit is 1024 chars; stay well under it so
-- a base with many Pals splits into multiple "(cont.)" fields instead of
-- silently truncating data. At max expected scale (3 bases x 20 Pals, one-
-- line-per-pal compact format) this keeps every field's total embed size
-- comfortably under Discord's 6000-char whole-message budget too.
local DISCORD_FIELD_VALUE_SOFT_LIMIT = 900

-- CharacterID (e.g. "PlantSlime") is an internal code, not the display name
-- shown in-game (e.g. "Gumoss"). PalNames.lua is a code -> display name table
-- scraped from paldb.cc's Pals_Table (also kept as JSON at palproject/data/pal_names.json).
local PAL_DISPLAY_NAMES = require("PalNames")

-- Config.lua reads Scripts/config.json (poll interval, Discord webhook settings).
-- Edit config.json, not this file, to change settings.
local config = require("Config")
local Discord = require("Discord")

do
    local webhookCount = 0
    for _ in pairs(config.guild_webhooks) do webhookCount = webhookCount + 1 end
    print(string.format(
        "[BaseInventoryLogger] Config loaded: poll_interval_seconds=%s, discord_enabled=%s, guild_webhooks configured=%d\n",
        tostring(config.poll_interval_seconds), tostring(config.discord_enabled), webhookCount))
end

-- Verbatim from CXXHeaderDump/Pal_enums.hpp -- EPalStatusPhysicalHealthType
local PHYSICAL_HEALTH_NAMES = {
    [0] = "Healthy",
    [1] = "MinorInjury",
    [2] = "Severe",
    [3] = "Dying",
    [4] = "DeadBody",
    [5] = "CloudCemetery",
}

-- Verbatim from CXXHeaderDump/Pal_enums.hpp -- EPalBaseCampWorkerSickType
local WORKER_SICK_NAMES = {
    [0] = "None",
    [1] = "Cold",
    [2] = "Sprain",
    [3] = "Bulimia",
    [4] = "GastricUlcer",
    [5] = "Fracture",
    [6] = "Weakness",
    [7] = "DepressionSprain",
    [8] = "DisturbingElement",
}

-- Verbatim from CXXHeaderDump/Pal_enums.hpp -- EPalWorkSuitability
local WORK_SUITABILITY_NAMES = {
    [0] = "None",
    [1] = "EmitFlame",
    [2] = "Watering",
    [3] = "Seeding",
    [4] = "GenerateElectricity",
    [5] = "Handcraft",
    [6] = "Collection",
    [7] = "Deforest",
    [8] = "Mining",
    [9] = "OilExtraction",
    [10] = "ProductMedicine",
    [11] = "Cool",
    [12] = "Transport",
    [13] = "MonsterFarm",
    [14] = "Anyone",
}

local function isValid(obj)
    if not obj then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

-- FGuid has no :ToString() here -- build a comparable/hashable key from its
-- raw A/B/C/D uint32 fields instead.
local function GuidKey(guid)
    if not guid then return nil end
    local ok, a, b, c, d = pcall(function() return guid.A, guid.B, guid.C, guid.D end)
    if not ok then return nil end
    return string.format("%08X-%08X-%08X-%08X", a, b, c, d)
end

-- FFixedPoint64 -> plain float, via UFixedPoint64MathLibrary's CDO.
local fixedPointLib = StaticFindObject("/Script/Pal.Default__FixedPoint64MathLibrary")

local function ToFloat(fixedPoint)
    if not fixedPoint then return nil end
    if isValid(fixedPointLib) then
        local ok, result = pcall(function() return fixedPointLib:Convert_FixedPoint64ToFloat(fixedPoint) end)
        if ok and result then return result end
    end
    local okVal, value = pcall(function() return fixedPoint.Value end)
    if okVal and value then return value / 1000, true end
    return nil
end

-- Builds a map of guildIdKey -> guildName by walking online players'
-- PlayerState.GuildBelongTo.
local function BuildGuildNameLookup()
    local lookup = {}
    local playerStates = FindAllOf("PalPlayerState")

    if playerStates then
        for _, ps in ipairs(playerStates) do
            if isValid(ps) then
                local guild = ps.GuildBelongTo
                if isValid(guild) then
                    local key = GuidKey(guild.ID)
                    local okName, name = pcall(function() return guild.GuildName:ToString() end)
                    if key and okName and name and name ~= "" then
                        lookup[key] = name
                    end
                end
            end
        end
    end

    return lookup
end


-- Same underlying fields as FormatStatus, returned as raw values instead of
-- a pre-formatted string, so both the console line and the nicer Discord
-- line can be built from one fetch without re-parsing text.
local function GetStatusValues(save)
    local hp = ToFloat(save.Hp)
    local maxHp, maxHpIsGuess = ToFloat(save.MaxHP)

    local okStomach, stomach = pcall(function() return save.FullStomach end)
    local okMaxStomach, maxStomach = pcall(function() return save.MaxFullStomach end)

    local okSanity, sanity = pcall(function() return save.SanityValue end)

    local okHealth, health = pcall(function() return save.PhysicalHealth end)
    local okSick, sick = pcall(function() return save.WorkerSick end)
    local okTask, task = pcall(function() return save.CurrentWorkSuitability end)

    return {
        hp = hp,
        maxHp = maxHp,
        maxHpIsGuess = maxHpIsGuess,
        stomach = okStomach and stomach or nil,
        maxStomach = okMaxStomach and maxStomach or nil,
        sanity = okSanity and sanity or nil,
        healthName = (okHealth and PHYSICAL_HEALTH_NAMES[health]) or "?",
        sickName = (okSick and WORKER_SICK_NAMES[sick]) or "?",
        taskName = (okTask and WORK_SUITABILITY_NAMES[task]) or "?",
    }
end

local function FormatStatusConsole(v)
    local hpStr = (v.hp and v.maxHp) and string.format("%.0f/%.0f%s", v.hp, v.maxHp, v.maxHpIsGuess and "(approx)" or "") or "?"
    local stomachStr = (v.stomach and v.maxStomach) and string.format("%.0f/%.0f", v.stomach, v.maxStomach) or "?"
    local sanityStr = v.sanity and string.format("%.0f", v.sanity) or "?"
    local sickPart = (v.sickName ~= "None" and v.sickName ~= "?") and (", sick=" .. v.sickName) or ""

    return string.format("hp=%s, stomach=%s, sanity=%s, health=%s%s, task=%s",
        hpStr, stomachStr, sanityStr, v.healthName, sickPart, v.taskName)
end

-- Single line per Pal, kept deliberately compact: at max scale (3 bases x
-- 20 Pals) a 2-line format would blow Discord's 1024-char-per-field limit
-- well before reaching even one full base. Species name is only shown when
-- it differs from the nickname (i.e. the player actually renamed it) to
-- avoid "Gumoss (Gumoss)"-style redundancy on the common case.
local function FormatPalLineForDiscord(nick, speciesName, level, v)
    local hpText = v.hp and string.format("%.0f", v.hp) or "?"
    local stomachText = (v.stomach and v.maxStomach) and string.format("%.0f/%.0f", v.stomach, v.maxStomach) or "?"
    local sanityText = v.sanity and string.format("%.0f", v.sanity) or "?"

    local badges = {}
    if v.healthName ~= "Healthy" and v.healthName ~= "?" then
        table.insert(badges, "⚠️" .. v.healthName)
    end
    if v.sickName ~= "None" and v.sickName ~= "?" then
        table.insert(badges, "🤒" .. v.sickName)
    end
    local badgeText = (#badges > 0) and (" " .. table.concat(badges, " ")) or ""

    local nameLabel = (nick ~= speciesName) and string.format("%s (%s)", nick, speciesName) or nick

    return string.format("🐾**%s** Lv%s ❤️%s 🍗%s 🧠%s 🔨%s%s",
        nameLabel, tostring(level), hpText, stomachText, sanityText, v.taskName, badgeText)
end

-- Always prints to console. If wantDiscordFields is true, ALSO returns a
-- list of {name, value} field chunks for this base (nil if unavailable) --
-- returned rather than appended to a shared table, so the caller can
-- distribute copies to multiple destination embeds (per-guild + "all")
-- without re-running the base/pal fetch or printing to console twice.
local function LogBaseCamp(base, baseLabel, guildName, wantDiscordFields)
    if not isValid(base) then return nil end

    local director = base.WorkerDirector
    if not isValid(director) then
        print(string.format("    %s: no valid WorkerDirector\n", baseLabel))
        return nil
    end

    local container = director.CharacterContainer
    if not isValid(container) then
        print(string.format("    %s: no valid CharacterContainer\n", baseLabel))
        return nil
    end

    local okNum, count = pcall(function() return container:Num() end)
    if not okNum or not count then
        print(string.format("    %s: could not read slot count\n", baseLabel))
        return nil
    end
    count = math.min(count, MAX_SLOTS_SAFETY_CAP)

    print(string.format("    %s (%d slot(s)):\n", baseLabel, count))

    local discordPalLines = wantDiscordFields and {}

    for i = 0, count - 1 do
        local okSlot, slot = pcall(function() return container:Get(i) end)

        if okSlot and isValid(slot) then
            local handle = slot.Handle

            if isValid(handle) then
                local okParam, param = pcall(function() return handle:TryGetIndividualParameter() end)

                if okParam and isValid(param) then
                    local save = param.SaveParameter
                    local okSpecies, speciesCode = pcall(function() return save.CharacterID:ToString() end)
                    local okNick, nick = pcall(function() return save.NickName:ToString() end)
                    local level = save.Level

                    speciesCode = okSpecies and speciesCode or "?"
                    local speciesName = PAL_DISPLAY_NAMES[speciesCode] or speciesCode
                    nick = (okNick and nick ~= "" and nick) or speciesName

                    local okValues, values = pcall(GetStatusValues, save)

                    local statusStr = (okValues and FormatStatusConsole(values)) or "(status unavailable)"
                    print(string.format("      [%d] %s (species=%s, level=%s) - %s\n",
                        i, nick, speciesName, tostring(level), statusStr))

                    if discordPalLines and okValues then
                        table.insert(discordPalLines, FormatPalLineForDiscord(nick, speciesName, level, values))
                    end
                else
                    print(string.format("      [%d] (handle valid but no individual parameter)\n", i))
                end
            else
                print(string.format("      [%d] (empty slot)\n", i))
            end
        else
            print(string.format("      [%d] (invalid slot)\n", i))
        end
    end

    if not (wantDiscordFields and discordPalLines and #discordPalLines > 0) then
        return nil
    end

    -- Greedily pack lines into a field until the next one would push it
    -- over the soft limit, then start a new "(cont.)" field. Handles a
    -- 20-Pal base without truncating data or needing real pagination.
    local fields = {}
    local chunkLines = {}
    local chunkLength = 0
    local chunkIndex = 1

    local function FlushChunk()
        if #chunkLines == 0 then return end
        local suffix = (chunkIndex > 1) and string.format(" (cont. %d)", chunkIndex) or ""
        table.insert(fields, {
            name = string.format("🏰 %s — %s%s", guildName, baseLabel, suffix),
            value = table.concat(chunkLines, "\n"),
            inline = false,
        })
        chunkLines = {}
        chunkLength = 0
        chunkIndex = chunkIndex + 1
    end

    for _, line in ipairs(discordPalLines) do
        if chunkLength + #line + 1 > DISCORD_FIELD_VALUE_SOFT_LIMIT then
            FlushChunk()
        end
        table.insert(chunkLines, line)
        chunkLength = chunkLength + #line + 1
    end
    FlushChunk()

    return fields
end

-- Sends one embed (all accumulated fields) to one webhook, if that webhook
-- is actually configured and there's anything to say.
local function SendGuildReport(title, webhookUrl, fields, guildCount, baseCount)
    if not webhookUrl or webhookUrl == "" or #fields == 0 then return end

    local embed = {
        title = title,
        description = string.format("%d guild(s), %d base(s)", guildCount, baseCount),
        color = 0x57F287, -- Discord green
        fields = fields,
        footer = "BaseInventoryLogger",
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    local ok, statusOrErr = Discord.SendEmbed(webhookUrl, embed)
    if not ok then
        print(string.format("[BaseInventoryLogger] Discord send failed (%s): %s\n", title, tostring(statusOrErr)))
    end
end

LoopAsync(config.poll_interval_seconds * 1000, function()
    local bases = FindAllOf("PalBaseCampModel")

    if not bases or #bases == 0 then
        print("[BaseInventoryLogger] No bases found on map\n")
        return false -- false/nil keeps the loop going; true would cancel it
    end

    local guildNameById = BuildGuildNameLookup()

    local guildBuckets = {}
    local guildOrder = {}

    for _, base in ipairs(bases) do
        if isValid(base) then
            local key = GuidKey(base.GroupIdBelongTo)
            local guildName = (key and guildNameById[key]) or "<no guild>"

            if not guildBuckets[guildName] then
                guildBuckets[guildName] = {}
                table.insert(guildOrder, guildName)
            end
            table.insert(guildBuckets[guildName], base)
        end
    end

    -- "all" is a reserved key in guild_webhooks for an admin webhook that
    -- gets every guild's fields combined into one report.
    local adminWebhook = config.guild_webhooks["all"]
    local allFields = adminWebhook and {} or nil
    local perGuildFields = {} -- guildName -> field list, only for guilds with a configured webhook

    print(string.format("[BaseInventoryLogger] --- Tick: %d guild(s), %d base(s) ---\n", #guildOrder, #bases))
    for _, guildName in ipairs(guildOrder) do
        local basesInGuild = guildBuckets[guildName]
        print(string.format("  Guild '%s' (%d base(s)):\n", guildName, #basesInGuild))

        local guildWebhook = config.guild_webhooks[guildName]
        local wantFields = config.discord_enabled and (adminWebhook or guildWebhook) ~= nil

        for baseIndex, base in ipairs(basesInGuild) do
            local fields = LogBaseCamp(base, string.format("Base %d", baseIndex), guildName, wantFields)
            if fields then
                for _, f in ipairs(fields) do
                    if allFields then table.insert(allFields, f) end
                    if guildWebhook then
                        perGuildFields[guildName] = perGuildFields[guildName] or {}
                        table.insert(perGuildFields[guildName], f)
                    end
                end
            end
        end
    end

    if config.discord_enabled then
        if allFields then
            SendGuildReport("📊 Palworld Base Report (All Guilds)", adminWebhook, allFields, #guildOrder, #bases)
        end
        for guildName, fields in pairs(perGuildFields) do
            SendGuildReport("📊 " .. guildName .. " Base Report", config.guild_webhooks[guildName],
                fields, 1, #fields > 0 and #guildBuckets[guildName] or 0)
        end
    end

    return false -- keep looping
end)

print("[BaseInventoryLogger] Mod loaded.\n")
