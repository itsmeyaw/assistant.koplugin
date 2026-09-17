local BaseHandler = require("api_handlers.base")
local EventStream = require("api_handlers.bedrock_eventstream")
local ToolExecutor = require("assistant_tool_executor")
local ASUtils = require("assistant_utils")
local json = require("rapidjson")
local koutil = require("util")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local strbuf = require("string.buffer")

local BedrockHandler = BaseHandler:new({ name = "bedrock", can_fetch_models = true })

local STREAM_ERROR_CODES = {
    throttlingException = 429,
    validationException = 400,
    modelStreamErrorException = 424,
    internalServerException = 500,
    serviceUnavailableException = 503,
}

local function get_text(block)
    local text = koutil.tableGetValue(block, "text")
    return type(text) == "string" and text or nil
end

function BedrockHandler:SyncOptions(querier)
    BaseHandler.SyncOptions(self, querier)
    self.converse_url = self:getConverseUrl()
    self.stream_url = self:getConverseStreamUrl()
end

function BedrockHandler:getConverseUrl()
    return self.base_url .. "/model/" .. self.model .. "/converse"
end

function BedrockHandler:getConverseStreamUrl()
    return self.base_url .. "/model/" .. self.model .. "/converse-stream"
end

function BedrockHandler:headers()
    return { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. self.api_key }
end

function BedrockHandler:convertMessages(messages)
    local system, converted = {}, {}
    if type(messages) ~= "table" then return converted, system end
    for message_index, message in ipairs(messages) do
        if type(message) == "table" then
            local role, content = message.role, message.content
            if role == "system" and type(content) == "string" then
                table.insert(system, { text = content })
            elseif (role == "user" or role == "assistant") and type(content) == "table" then
                -- Tool loop messages are already Bedrock wire objects; do not flatten them.
                table.insert(converted, { role = role, content = content })
            elseif (role == "user" or role == "assistant") and type(content) == "string" then
                table.insert(converted, { role = role, content = { { text = content } } })
            end
        end
    end
    return converted, system
end

function BedrockHandler:buildRequestBody(messages, query_option, tools)
    local converted, system = self:convertMessages(messages)
    local body = { messages = converted }
    if #system > 0 then body.system = system end
    local params = self.additional_parameters
    if type(params) == "table" then
        local inference = {}
        if params.max_tokens ~= nil then inference.maxTokens = params.max_tokens end
        if params.temperature ~= nil then inference.temperature = params.temperature end
        if params.top_p ~= nil then inference.topP = params.top_p end
        if params.stop_sequences ~= nil then inference.stopSequences = params.stop_sequences end
        if next(inference) then body.inferenceConfig = inference end
        if type(params.additional_model_request_fields) == "table" then
            body.additionalModelRequestFields = params.additional_model_request_fields
        end
    end
    if tools then body.toolConfig = { tools = tools } end
    return body
end

function BedrockHandler:Test()
    local body = { messages = { { role = "user", content = { { text = self.TEST_PROMPT } } } } }
    return self:testRequest(self:getConverseUrl(), self:headers(), body, function(data)
        local content = koutil.tableGetValue(data, "output", "message", "content")
        if type(content) ~= "table" then return nil end
        local text = {}
        for block_index, block in ipairs(content) do
            local value = get_text(block)
            if value then table.insert(text, value) end
        end
        return #text > 0 and table.concat(text) or nil
    end)
end

local function stream_error(fd, handler, code, status, raw_body, headers)
    ffiutil.writeToFD(fd, "\r\n" .. handler.PROTOCOL_NON_200 .. json.encode({
        code = code, status = status, raw_body = raw_body, resp_headers = headers,
    }) .. "\r\n")
end

function BedrockHandler.wrapStreamEvent(event_type, payload)
    if type(event_type) ~= "string" or event_type == "" then
        return nil, "Bedrock EventStream event is missing :event-type"
    end
    if type(payload) ~= "table" then
        return nil, "Invalid Bedrock event payload"
    end
    return { eventType = { [event_type] = payload } }
end

function BedrockHandler:backgroundRequest(url, headers, body)
    return function(pid, child_write_fd)
        if not pid or not child_write_fd then return end
        if url:sub(1, 5) == "https" then https.cert_verify = false end
        local decoder, raw = EventStream.new(), strbuf.new()
        local failed
        local function fail(code, status, detail)
            if not failed then failed = { code = code, status = status, detail = detail } end
        end
        local function sink(chunk)
            if not chunk then return true end
            raw:put(chunk)
            if failed then return true end
            local frames, err = decoder:feed(chunk)
            if not frames then fail("BEDROCK_EVENTSTREAM", "ProtocolError", err); return true end
            for frame_index, frame in ipairs(frames) do
                local message_type = koutil.tableGetValue(frame, "headers", ":message-type")
                local event_type = koutil.tableGetValue(frame, "headers", ":event-type")
                local error_type = koutil.tableGetValue(frame, "headers", ":exception-type")
                    or koutil.tableGetValue(frame, "headers", ":error-code")
                local error_message = koutil.tableGetValue(frame, "headers", ":error-message")
                local error_key = type(error_type) == "string" and error_type or nil
                if message_type == "error" then
                    local raw_error = json.encode({ code = error_key, message = error_message })
                    fail(STREAM_ERROR_CODES[error_key] or error_key or "BedrockError", error_key or "BedrockError", raw_error)
                    break
                end
                local ok, payload = pcall(json.decode, frame.payload)
                if not ok or type(payload) ~= "table" then
                    fail("BEDROCK_EVENTSTREAM", "InvalidPayload", "Invalid Bedrock event payload")
                    break
                end
                if message_type == "exception" or error_type then
                    local exception = error_key or event_type or "BedrockException"
                    fail(STREAM_ERROR_CODES[exception] or exception, exception, frame.payload)
                    break
                end
                local event, wrap_err = self.wrapStreamEvent(event_type, payload)
                if not event then
                    fail("BEDROCK_EVENTSTREAM", "ProtocolError", wrap_err)
                    break
                end
                ffiutil.writeToFD(child_write_fd, "data: " .. json.encode(event) .. "\n\n")
            end
            return true
        end
        local code, resp_headers, status = socket.skip(1, http.request({
            url = url, method = "POST", headers = headers, source = ltn12.source.string(body), sink = sink,
        }))
        if code ~= 200 then
            stream_error(child_write_fd, self, code, status, raw:tostring(), resp_headers)
        elseif failed then
            stream_error(child_write_fd, self, failed.code, failed.status, failed.detail, resp_headers)
        else
            local ok, err = decoder:finish()
            if not ok then
                stream_error(child_write_fd, self, "BEDROCK_EVENTSTREAM", "ProtocolError", err, resp_headers)
            else
                ffiutil.writeToFD(child_write_fd, "data: [DONE]\n\n")
            end
        end
        ffi.C.close(child_write_fd)
    end
end

function BedrockHandler:query(message_history, query_option)
    local tools
    if ToolExecutor.IsExtSearch(query_option.use_websearch or "none") then
        tools = { self:buildExternalSearchToolDef("bedrock") }
    end
    local body = self:buildRequestBody(message_history, query_option, tools)
    if query_option.use_stream_mode then
        return self:backgroundRequest(self:getConverseStreamUrl(), self:headers(), json.encode(body))
    end
    local success, code, response = self:makeRequest(self:getConverseUrl(), self:headers(), json.encode(body))
    if not success then
        local ok, decoded = type(response) == "string" and pcall(json.decode, response)
        local detail = ok and type(decoded) == "table" and ASUtils.extractErrorMessage(decoded) or nil
        return nil, detail or tostring(response or code)
    end
    local ok, data = pcall(json.decode, response)
    if not ok or type(data) ~= "table" then return nil, "Failed to parse Bedrock response" end
    local api_error = ASUtils.extractErrorMessage(data)
    if api_error then return nil, api_error end
    return self:parseToolCalls(data, "bedrock")
end

function BedrockHandler:FetchModels()
    local control = self.base_url:gsub("^https://bedrock%-runtime%.", "https://bedrock.")
    if control == self.base_url then return nil, "Bedrock runtime URL cannot be mapped to a control-plane URL" end
    local headers = self:headers()
    local foundation, foundation_err = ASUtils.fetchJSON(control .. "/foundation-models?byOutputModality=TEXT", headers)
    local profiles, profiles_err = ASUtils.fetchJSON(control .. "/inference-profiles?maxResults=1000", headers)
    local entries = {}
    local function add(items, id_key, name_key, status_path, require_streaming)
        if type(items) ~= "table" then return end
        for item_index, item in ipairs(items) do
            local id = koutil.tableGetValue(item, id_key)
            local status = koutil.tableGetValue(item, unpack(status_path))
            local streaming = koutil.tableGetValue(item, "responseStreamingSupported")
            if type(id) == "string" and (status == nil or status == "ACTIVE")
                and (not require_streaming or streaming ~= false) then
                entries[id] = { id = id, name = koutil.tableGetValue(item, name_key) or id }
            end
        end
    end
    add(koutil.tableGetValue(foundation, "modelSummaries"), "modelId", "modelName", { "modelLifecycle", "status" }, true)
    add(koutil.tableGetValue(profiles, "inferenceProfileSummaries"), "inferenceProfileId", "inferenceProfileName", { "status" })
    local result = {}
    for id, entry in pairs(entries) do table.insert(result, entry) end
    table.sort(result, function(a, b) return a.id < b.id end)
    if #result > 0 then return result end
    return nil, foundation_err or profiles_err or "Failed to fetch Bedrock models"
end

return BedrockHandler
