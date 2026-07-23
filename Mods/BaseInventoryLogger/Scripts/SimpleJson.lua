-- Minimal FLAT JSON object parser -- no nesting, no arrays. UE4SS's Lua
-- sandbox ships no JSON library (confirmed: no http/json globals, and the
-- only game-side JSON utility class only builds header maps, not a decoder).
-- Full JSON parsing is unnecessary for a simple config file, so this only
-- understands: {"key": "string", "key": 123, "key": true/false/null}

local SimpleJson = {}

function SimpleJson.DecodeFlat(text)
    local result = {}
    if not text then return result end

    for key, value in text:gmatch('"([%w_]+)"%s*:%s*"(.-[^\\])"') do
        result[key] = value:gsub("\\(.)", "%1") -- unescape \" \\ etc.
    end
    for key, value in text:gmatch('"([%w_]+)"%s*:%s*(%-?%d+%.?%d*)%s*[,}]') do
        if result[key] == nil then result[key] = tonumber(value) end
    end
    for key in text:gmatch('"([%w_]+)"%s*:%s*true%s*[,}]') do
        result[key] = true
    end
    for key in text:gmatch('"([%w_]+)"%s*:%s*false%s*[,}]') do
        result[key] = false
    end

    return result
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
