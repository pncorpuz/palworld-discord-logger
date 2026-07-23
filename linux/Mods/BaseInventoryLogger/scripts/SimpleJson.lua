-- Minimal JSON helpers -- no general parser. UE4SS's Lua sandbox ships no
-- JSON library (confirmed: no http/json globals, and the only game-side
-- JSON utility class only builds header maps, not a decoder). Config needs
-- are simple enough that a full parser is unnecessary:
--   DecodeFlat   -- a flat {"key": "string"/number/bool, ...} object
--   ExtractObject -- pulls one named nested {...} object's raw text out of a
--                    larger document (via balanced-brace matching), so its
--                    contents can then be run through DecodeFlat too. Only
--                    one level of nesting is supported -- that's all
--                    config.json (guild_webhooks) needs.

local SimpleJson = {}

-- Keys are any non-quote text (guild names can have spaces/emoji/etc, not
-- just [%w_]) -- matches how string VALUES are already handled.
function SimpleJson.DecodeFlat(text)
    local result = {}
    if not text then return result end

    for key, value in text:gmatch('"([^"]+)"%s*:%s*"(.-[^\\])"') do
        result[key] = value:gsub("\\(.)", "%1") -- unescape \" \\ etc.
    end
    for key, value in text:gmatch('"([^"]+)"%s*:%s*(%-?%d+%.?%d*)%s*[,}]') do
        if result[key] == nil then result[key] = tonumber(value) end
    end
    for key in text:gmatch('"([^"]+)"%s*:%s*true%s*[,}]') do
        result[key] = true
    end
    for key in text:gmatch('"([^"]+)"%s*:%s*false%s*[,}]') do
        result[key] = false
    end

    return result
end

-- Finds "key": { ... } in `text` and returns the raw "{ ... }" substring
-- (including braces), or nil if not found / unbalanced. Handles nested
-- braces within via depth counting, so it's safe even if a value inside
-- happens to contain "{" or "}" characters in a string.
function SimpleJson.ExtractObject(text, key)
    if not text then return nil end

    local keyPos = text:find('"' .. key:gsub("(%W)", "%%%1") .. '"%s*:%s*{')
    if not keyPos then return nil end

    local braceStart = text:find("{", keyPos)
    local depth = 0
    for i = braceStart, #text do
        local c = text:sub(i, i)
        if c == "{" then
            depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then
                return text:sub(braceStart, i)
            end
        end
    end
    return nil -- unbalanced braces
end

-- Escapes a Lua string for safe embedding as a JSON string value.
function SimpleJson.EscapeString(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    return s
end

return SimpleJson
