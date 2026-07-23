-- Sends messages/embeds to a Discord webhook, editing the same message on
-- later calls instead of spamming a new one every tick.
-- LINUX BUILD (ue4ss-linux / XarminaEu) -- adapted from the Windows version.
--
-- UE4SS's Lua sandbox has NO networking/HTTP capability at all (confirmed on
-- the Windows build: no http.* global, and the game's own
-- UHttpBlueprintFunctionLibrary only builds header maps, no send-request
-- function -- assumed to hold here too, since it's the same underlying game
-- code). Standard Lua's `io`/`os` libraries are available on Windows UE4SS
-- ("on top of the standard libraries Lua comes with by default" per docs);
-- UNVERIFIED whether ue4ss-linux's Lua state also exposes them the same way
-- -- if io.popen fails outright here, that's the first thing to check.
-- Shells out to `curl` (not `curl.exe` -- no extension on Linux) via
-- io.popen for the actual HTTP calls.
--
-- Edit-in-place mechanics: Discord's webhook execute endpoint (POST) only
-- returns the created message's JSON (with its id) if called with
-- `?wait=true` -- otherwise it's fire-and-forget (204, no body). The id is
-- persisted to a small state file, ONE PER WEBHOOK (named by the webhook's
-- own id, since multiple webhooks are now in play with per-guild routing),
-- so later ticks can PATCH /webhooks/{id}/{token}/messages/{message_id}
-- instead of POSTing a new message each time. No extra auth needed for the
-- PATCH beyond the webhook token already embedded in the URL, since it's
-- editing its own message.
--
-- All request/response bodies go through temp files rather than inline on
-- the command line, to avoid shell quoting rules mangling embedded
-- quotes/braces in JSON payloads. This also means the same approach should
-- carry over cleanly from cmd.exe (Windows) to /bin/sh (Linux, via
-- io.popen) without changes beyond the path prefix below.
--
-- No general JSON encoder exists in this environment (see SimpleJson.lua),
-- so embed JSON is hand-built for this exact shape (title/description/color/
-- fields[]/footer/timestamp) rather than attempting generic serialization.

local SimpleJson = require("SimpleJson")

local Discord = {}

-- ue4ss-linux has no nested "ue4ss/" subfolder like the Windows install --
-- libUE4SS.so and Mods/ sit directly in Binaries/Linux/. UNVERIFIED -- check
-- UE4SS.log's own reported working directory if temp files aren't appearing
-- where expected, same as Config.lua's path candidates.
local SCRIPTS_DIR = "Mods/BaseInventoryLogger/scripts/"
local PAYLOAD_PATH = SCRIPTS_DIR .. "discord_payload.tmp.json"
local RESPONSE_PATH = SCRIPTS_DIR .. "discord_response.tmp.json"

local MAX_CONTENT_LENGTH = 1900   -- Discord content hard limit is 2000
local MAX_FIELD_VALUE_LENGTH = 1024 -- Discord embed field value hard limit
local MAX_FIELDS = 25             -- Discord embed field count hard limit

local function MessageIdPath(webhookId)
    return SCRIPTS_DIR .. "discord_message_id_" .. tostring(webhookId) .. ".txt"
end

local function ReadMessageId(webhookId)
    local f = io.open(MessageIdPath(webhookId), "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text and text:match("%d+")
end

local function WriteMessageId(webhookId, id)
    local f = io.open(MessageIdPath(webhookId), "w")
    if not f then return end
    f:write(id)
    f:close()
end

-- Standard webhook URL shape: https://discord.com/api/webhooks/{id}/{token}
local function ParseWebhookUrl(url)
    return url:match("/api/webhooks/(%d+)/([%w_%-]+)")
end

-- Runs one curl call, writes the response body to RESPONSE_PATH, and
-- returns (httpStatusCode, responseBodyText).
local function RunCurl(method, url, payloadPath)
    local command = string.format(
        'curl -s -o "%s" -w "%%{http_code}" -X %s -H "Content-Type: application/json" -d @%s "%s"',
        RESPONSE_PATH, method, payloadPath, url)

    local handle, popenErr = io.popen(command, "r")
    if not handle then
        return nil, nil, "io.popen failed: " .. tostring(popenErr)
    end
    local statusText = handle:read("*a")
    handle:close()

    local status = statusText and tonumber(statusText:match("%d+"))

    local body = nil
    local rf = io.open(RESPONSE_PATH, "r")
    if rf then
        body = rf:read("*a")
        rf:close()
    end

    return status, body
end

-- Shared send-or-edit plumbing for any already-built JSON payload string.
local function SendPayload(webhookUrl, jsonBody)
    if not webhookUrl or webhookUrl == "" then
        return false, "no webhook URL configured"
    end

    local file, openErr = io.open(PAYLOAD_PATH, "w")
    if not file then
        return false, "could not write payload temp file: " .. tostring(openErr)
    end
    file:write(jsonBody)
    file:close()

    local webhookId, webhookToken = ParseWebhookUrl(webhookUrl)
    local existingMessageId = webhookId and ReadMessageId(webhookId)

    if existingMessageId and webhookToken then
        local editUrl = string.format("https://discord.com/api/webhooks/%s/%s/messages/%s",
            webhookId, webhookToken, existingMessageId)
        local status = RunCurl("PATCH", editUrl, PAYLOAD_PATH)

        if status and status < 300 then
            return true, "edited existing message (" .. tostring(status) .. ")"
        end
        -- Edit failed (message deleted, too old, or a stale id from a
        -- previous run) -- fall through and post a fresh one below.
    end

    local postUrl = webhookUrl .. (webhookUrl:find("?") and "&wait=true" or "?wait=true")
    local status, responseBody = RunCurl("POST", postUrl, PAYLOAD_PATH)

    if status and status < 300 then
        local newId = responseBody and responseBody:match('"id"%s*:%s*"(%d+)"')
        if newId and webhookId then WriteMessageId(webhookId, newId) end
        return true, "posted new message (" .. tostring(status) .. ")"
    end

    return false, "unexpected HTTP status: " .. tostring(status)
end

function Discord.SendMessage(webhookUrl, content)
    if #content > MAX_CONTENT_LENGTH then
        content = content:sub(1, MAX_CONTENT_LENGTH - 15) .. "\n...(truncated)"
    end
    local jsonBody = string.format('{"content":"%s"}', SimpleJson.EscapeString(content))
    return SendPayload(webhookUrl, jsonBody)
end

-- embed = {
--   title = string, description = string?, color = integer (0xRRGGBB),
--   fields = { { name = string, value = string, inline = bool? }, ... },
--   footer = string?, timestamp = string? (ISO 8601, e.g. os.date("!%Y-%m-%dT%H:%M:%SZ")),
-- }
function Discord.SendEmbed(webhookUrl, embed)
    local fieldsJson = {}
    for i, f in ipairs(embed.fields or {}) do
        if i > MAX_FIELDS then break end
        local value = f.value or ""
        if #value > MAX_FIELD_VALUE_LENGTH then
            value = value:sub(1, MAX_FIELD_VALUE_LENGTH - 15) .. "\n...(truncated)"
        end
        table.insert(fieldsJson, string.format(
            '{"name":"%s","value":"%s","inline":%s}',
            SimpleJson.EscapeString(f.name or ""),
            SimpleJson.EscapeString(value),
            f.inline and "true" or "false"))
    end

    local parts = {}
    table.insert(parts, string.format('"title":"%s"', SimpleJson.EscapeString(embed.title or "")))
    if embed.description then
        table.insert(parts, string.format('"description":"%s"', SimpleJson.EscapeString(embed.description)))
    end
    table.insert(parts, string.format('"color":%d', embed.color or 0))
    table.insert(parts, string.format('"fields":[%s]', table.concat(fieldsJson, ",")))
    if embed.footer then
        table.insert(parts, string.format('"footer":{"text":"%s"}', SimpleJson.EscapeString(embed.footer)))
    end
    if embed.timestamp then
        table.insert(parts, string.format('"timestamp":"%s"', embed.timestamp))
    end

    -- "content":"" explicitly clears any leftover plain-text content from a
    -- prior SendMessage on this same edited message -- PATCH only overwrites
    -- fields present in the payload, so omitting content here would leave
    -- old text sitting above the embed forever.
    local jsonBody = string.format('{"content":"","embeds":[{%s}]}', table.concat(parts, ","))
    return SendPayload(webhookUrl, jsonBody)
end

return Discord
