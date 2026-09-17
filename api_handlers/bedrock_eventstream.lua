local bit = require("bit")

local EventStream = {}
EventStream.__index = EventStream

local MAX_MESSAGE_SIZE = 16 * 1024 * 1024
local MIN_MESSAGE_SIZE = 16
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
    if value < 0 then
        return value + UINT32
    end
    return value
end

local function crc32(data)
    local value = -1
    for index = 1, #data do
        value = bit.bxor(bit.rshift(value, 8), CRC32_TABLE[bit.band(bit.bxor(value, data:byte(index)), 0xff)])
    end
    return unsigned(bit.bnot(value))
end

local function read_u16(data, index)
    local first, second = data:byte(index, index + 1)
    return first * 256 + second
end

local function read_u32(data, index)
    local first, second, third, fourth = data:byte(index, index + 3)
    return ((first * 256 + second) * 256 + third) * 256 + fourth
end

local function read_signed(data, index, bytes)
    if bytes == 8 then
        local high = read_u32(data, index)
        local low = read_u32(data, index + 4)
        if high >= UINT32 / 2 then
            return (high - UINT32) * UINT32 + low
        end
        return high * UINT32 + low
    end
    local value = 0
    for offset = 0, bytes - 1 do
        value = value * 256 + data:byte(index + offset)
    end
    local sign = 256 ^ bytes / 2
    if value >= sign then
        return value - sign * 2
    end
    return value
end

local function parse_headers(data, first, last)
    local headers = {}
    local index = first

    while index <= last do
        local name_length = data:byte(index)
        if not name_length or name_length == 0 then
            return nil, "invalid Amazon EventStream header name"
        end
        index = index + 1
        if index + name_length > last + 1 then
            return nil, "truncated Amazon EventStream header name"
        end
        local name = data:sub(index, index + name_length - 1)
        index = index + name_length

        local value_type = data:byte(index)
        if not value_type then
            return nil, "truncated Amazon EventStream header type"
        end
        index = index + 1

        local value_length = 0
        local value
        if value_type == 0 then
            value = true
        elseif value_type == 1 then
            value = false
        elseif value_type == 2 then
            value_length = 1
        elseif value_type == 3 then
            value_length = 2
        elseif value_type == 4 then
            value_length = 4
        elseif value_type == 5 or value_type == 8 then
            value_length = 8
        elseif value_type == 6 or value_type == 7 then
            if index + 1 > last then
                return nil, "truncated Amazon EventStream header value length"
            end
            value_length = read_u16(data, index)
            index = index + 2
        elseif value_type == 9 then
            value_length = 16
        else
            return nil, "invalid Amazon EventStream header type"
        end

        if index + value_length > last + 1 then
            return nil, "truncated Amazon EventStream header value"
        end
        if value_type == 2 or value_type == 3 or value_type == 4 or value_type == 5 or value_type == 8 then
            value = read_signed(data, index, value_length)
        elseif value_type == 6 or value_type == 7 or value_type == 9 then
            value = data:sub(index, index + value_length - 1)
        end
        headers[name] = value
        index = index + value_length
    end

    return headers
end

function EventStream.new()
    return setmetatable({ buffer = false }, EventStream)
end

function EventStream:fail(message)
    self.error = message
    return nil, message
end

function EventStream:feed(chunk)
    if self.error then
        return nil, self.error
    end
    if type(chunk) ~= "string" then
        return self:fail("Amazon EventStream chunk must be a string")
    end

    self.buffer = (self.buffer or "") .. chunk
    local messages = {}
    while #self.buffer >= 12 do
        local total_length = read_u32(self.buffer, 1)
        local headers_length = read_u32(self.buffer, 5)
        if read_u32(self.buffer, 9) ~= crc32(self.buffer:sub(1, 8)) then
            return self:fail("invalid Amazon EventStream prelude CRC")
        end
        if total_length < MIN_MESSAGE_SIZE or total_length > MAX_MESSAGE_SIZE then
            return self:fail("invalid Amazon EventStream message length")
        end
        if headers_length > total_length - MIN_MESSAGE_SIZE then
            return self:fail("invalid Amazon EventStream headers length")
        end
        if #self.buffer < total_length then
            break
        end

        local message = self.buffer:sub(1, total_length)
        if read_u32(message, total_length - 3) ~= crc32(message:sub(1, total_length - 4)) then
            return self:fail("invalid Amazon EventStream message CRC")
        end
        local headers, err = parse_headers(message, 13, 12 + headers_length)
        if not headers then
            return self:fail(err)
        end
        messages[#messages + 1] = {
            headers = headers,
            payload = message:sub(13 + headers_length, total_length - 4),
        }
        self.buffer = self.buffer:sub(total_length + 1)
    end

    return messages
end

function EventStream:finish()
    if self.error then
        return nil, self.error
    end
    if self.buffer and #self.buffer > 0 then
        return self:fail("truncated Amazon EventStream message")
    end
    return true
end

return EventStream
