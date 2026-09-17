local helper = require("test.helper")
local assert = helper.assert
local bit = require("bit")
local EventStream = require("api_handlers/bedrock_eventstream")

local KNOWN_FRAME = "\000\000\000)\000\000\000\020\179)Fa\011:event-type\007\000\005chunkhello\179\207\239\128"
local UINT32 = 4294967296
local CRC32_TABLE = {}
for byte = 0, 255 do
    local value = byte
    for bit_index = 1, 8 do
        if bit.band(value, 1) ~= 0 then
            value = bit.bxor(bit.rshift(value, 1), 0xedb88320)
        else
            value = bit.rshift(value, 1)
        end
    end
    CRC32_TABLE[byte] = value
end

local function unsigned(value)
    return value < 0 and value + UINT32 or value
end

local function crc32(data)
    local value = -1
    for index = 1, #data do
        value = bit.bxor(bit.rshift(value, 8), CRC32_TABLE[bit.band(bit.bxor(value, data:byte(index)), 0xff)])
    end
    return unsigned(bit.bnot(value))
end

local function u16(value)
    return string.char(math.floor(value / 256), value % 256)
end

local function u32(value)
    return string.char(math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256, value % 256)
end

local function header(name, value_type, value)
    return string.char(#name) .. name .. string.char(value_type) .. (value or "")
end

local function frame(headers, payload)
    local prelude = u32(16 + #headers + #payload) .. u32(#headers)
    prelude = prelude .. u32(crc32(prelude))
    local body = prelude .. headers .. payload
    return body .. u32(crc32(body))
end

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("decodes an externally generated CRC frame", function()
        local decoder = EventStream.new()
        local events = decoder:feed(KNOWN_FRAME)
        assert.equal(#events, 1)
        assert.equal(events[1].headers[":event-type"], "chunk")
        assert.equal(events[1].payload, "hello")
    end),

    test("decodes one event with string headers and raw payload", function()
        local decoder = EventStream:new()
        local events = decoder:feed(frame(header(":event-type", 7, u16(5) .. "chunk"), "hello"))
        assert.equal(#events, 1)
        assert.equal(events[1].headers[":event-type"], "chunk")
        assert.equal(events[1].payload, "hello")
        assert.isTrue(decoder:finish())
    end),

    test("decodes multiple events in one chunk", function()
        local decoder = EventStream:new()
        local events = decoder:feed(frame(header("a", 7, u16(1) .. "x"), "one") .. frame(header("b", 7, u16(1) .. "y"), "two"))
        assert.equal(#events, 2)
        assert.equal(events[2].headers.b, "y")
        assert.equal(events[2].payload, "two")
    end),

    test("preserves frames across every byte boundary and retains all header types", function()
        local headers = header("true", 0) .. header("false", 1) .. header("byte", 2, "\255") .. header("short", 3, "\255\254")
            .. header("int", 4, "\255\255\255\254") .. header("long", 5, string.rep("\255", 7) .. "\253")
            .. header("bytes", 6, u16(2) .. "ok") .. header("time", 8, string.rep("\255", 7) .. "\252")
            .. header("uuid", 9, "1234567890abcdef") .. header("text", 7, u16(4) .. "done")
        local encoded = frame(headers, "payload")
        local decoder = EventStream:new()
        local events = {}
        for index = 1, #encoded do
            local decoded = decoder:feed(encoded:sub(index, index))
            for event_index, event in ipairs(decoded) do
                events[#events + 1] = event
            end
        end
        assert.equal(#events, 1)
        assert.equal(events[1].headers["true"], true)
        assert.equal(events[1].headers["false"], false)
        assert.equal(events[1].headers.byte, -1)
        assert.equal(events[1].headers.short, -2)
        assert.equal(events[1].headers.int, -2)
        assert.equal(events[1].headers.long, -3)
        assert.equal(events[1].headers.bytes, "ok")
        assert.equal(events[1].headers.time, -4)
        assert.equal(events[1].headers.uuid, "1234567890abcdef")
        assert.equal(events[1].headers.text, "done")
        assert.equal(events[1].payload, "payload")
    end),

    test("rejects an invalid prelude CRC and retains the error", function()
        local encoded = frame("", "payload")
        local decoder = EventStream:new()
        local events, err = decoder:feed(encoded:sub(1, 8) .. "\000\000\000\000" .. encoded:sub(13))
        assert.equal(events, nil)
        assert.matches(err, "prelude CRC")
        events, err = decoder:feed("")
        assert.equal(events, nil)
        assert.matches(err, "prelude CRC")
    end),

    test("rejects an invalid message CRC", function()
        local encoded = frame("", "payload")
        local decoder = EventStream:new()
        local events, err = decoder:feed(encoded:sub(1, -2) .. string.char(bit.bxor(encoded:byte(-1), 1)))
        assert.equal(events, nil)
        assert.matches(err, "message CRC")
    end),

    test("rejects malformed lengths", function()
        local prelude = u32(15) .. u32(0)
        local decoder = EventStream:new()
        local events, err = decoder:feed(prelude .. u32(crc32(prelude)))
        assert.equal(events, nil)
        assert.matches(err, "message length")

        prelude = u32(16) .. u32(1)
        decoder = EventStream:new()
        events, err = decoder:feed(prelude .. u32(crc32(prelude)))
        assert.equal(events, nil)
        assert.matches(err, "headers length")
    end),

    test("rejects malformed header names and types", function()
        local decoder = EventStream:new()
        local events, err = decoder:feed(frame("\000", ""))
        assert.equal(events, nil)
        assert.matches(err, "header name")

        decoder = EventStream:new()
        events, err = decoder:feed(frame("\002a", ""))
        assert.equal(events, nil)
        assert.matches(err, "header name")

        decoder = EventStream:new()
        events, err = decoder:feed(frame("\001a", ""))
        assert.equal(events, nil)
        assert.matches(err, "header type")

        decoder = EventStream:new()
        events, err = decoder:feed(frame("\001a\007\000", ""))
        assert.equal(events, nil)
        assert.matches(err, "value length")

        decoder = EventStream:new()
        events, err = decoder:feed(frame("\001a\007\000\002x", ""))
        assert.equal(events, nil)
        assert.matches(err, "header value")

        decoder = EventStream:new()
        events, err = decoder:feed(frame("\001a\010", ""))
        assert.equal(events, nil)
        assert.matches(err, "header type")
    end),

    test("finish rejects a truncated stream", function()
        local decoder = EventStream:new()
        assert.equal(#decoder:feed(frame("", "payload"):sub(1, 14)), 0)
        local ok, err = decoder:finish()
        assert.equal(ok, nil)
        assert.matches(err, "truncated")
    end),
}

return helper.runTests("bedrock_eventstream", tests)
