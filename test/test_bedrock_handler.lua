local helper = require("test.helper")
local assert = helper.assert
local json = require("rapidjson")
local strbuf = require("string.buffer")
local Bedrock = require("api_handlers.bedrock")
local ToolExecutor = require("assistant_tool_executor")
local Querier = require("assistant_querier")

local function handler()
    return Bedrock:new({
        base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        model = "anthropic.claude-test", api_key = "key", additional_parameters = {},
    })
end

local tests = {
    { name = "builds endpoints auth and Bedrock body", fn = function()
        local h = handler()
        h:SyncOptions({ provider_name = "p", handler_name = "bedrock", provider_setting = {
            base_url = h.base_url, model = h.model, api_key = h.api_key, additional_parameters = {},
        },
            settings = { readSetting = function() end } })
        assert.equal("https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-test/converse", h.converse_url)
        assert.equal("Bearer key", h:headers().Authorization)
        h.additional_parameters = { max_tokens = 4, temperature = 0.2, top_p = 0.8,
            stop_sequences = { "END" }, ignored = true, additional_model_request_fields = { foo = 1 } }
        local body = h:buildRequestBody({ { role = "system", content = "rules" },
            { role = "user", content = "hi" }, { role = "assistant", content = "ok" } }, {}, nil)
        assert.equal("rules", body.system[1].text)
        assert.equal("hi", body.messages[1].content[1].text)
        assert.equal(4, body.inferenceConfig.maxTokens)
        assert.equal(0.8, body.inferenceConfig.topP)
        assert.equal(nil, body.ignored)
        assert.equal(1, body.additionalModelRequestFields.foo)
    end },
    { name = "preserves native tool messages and ignores malformed history", fn = function()
        local body = handler():buildRequestBody({ false, { role = "assistant", content = {
            { toolUse = { toolUseId = "t", name = "assistant_web_search", input = {} } } } },
            { role = "user", content = { { toolResult = { toolUseId = "t", content = {} } } } } }, {}, nil)
        assert.equal("t", body.messages[1].content[1].toolUse.toolUseId)
        assert.equal("t", body.messages[2].content[1].toolResult.toolUseId)
    end },
    { name = "parses text and multiple tools", fn = function()
        local h = handler()
        local result = h:parseToolCalls({ output = { message = { content = { { text = "one" }, { text = "two" } } } } }, "bedrock")
        assert.equal("onetwo", result)
        local calls = h:parseToolCalls({ output = { message = { content = { { toolUse = {
            toolUseId = "a", name = "assistant_web_search", input = { keywords = "a" } } }, { toolUse = {
            toolUseId = "b", name = "assistant_web_search", input = { keywords = "b" } } } } } } }, "bedrock")
        assert.isTrue(calls.__is_tool_call)
        assert.equal(2, #calls.tool_calls)
    end },
    { name = "builds Bedrock tools and result messages", fn = function()
        local tool = ToolExecutor.buildExternalSearchToolDef("bedrock")
        assert.equal("assistant_web_search", tool.toolSpec.name)
        assert.equal("object", tool.toolSpec.inputSchema.json.type)
        local history = {}
        local ok = ToolExecutor.appendToolResult(history, { format = "bedrock", raw_assistant = {
            role = "assistant", content = {} }, search_results = { { tool_call_id = "x", search_result = "found", search_keywords = "q" } } })
        assert.isTrue(ok)
        assert.equal("found", history[2].content[1].toolResult.content[1].text)
    end },
    { name = "normalizes partial model responses", fn = function()
        helper.mockFetchJSON({ { parsed = { modelSummaries = { { modelId = "a", modelName = "A", modelLifecycle = { status = "ACTIVE" } },
            { modelId = "gone", modelLifecycle = { status = "LEGACY" } } } } }, { parsed = nil, err = "profiles down" } })
        local models = handler():FetchModels()
        assert.equal(1, #models)
        assert.equal("a", models[1].id)
    end },
    { name = "deduplicates and sorts model ids", fn = function()
        helper.mockFetchJSON({ { parsed = { modelSummaries = { { modelId = "z", modelLifecycle = { status = "ACTIVE" } },
            { modelId = "a", modelLifecycle = { status = "ACTIVE" } } } } }, { parsed = {
            inferenceProfileSummaries = { { inferenceProfileId = "a", inferenceProfileName = "Profile", status = "ACTIVE" } } } } })
        local models = handler():FetchModels()
        assert.equal(2, #models)
        assert.equal("a", models[1].id)
        assert.equal("z", models[2].id)
    end },
    { name = "accumulates Bedrock stream tool inputs", fn = function()
        local q = setmetatable({}, { __index = Querier })
        local result, reasoning = strbuf.new(), strbuf.new()
        local acc = { current = {}, tools = {} }
        q:processChunk({ eventType = { contentBlockStart = { contentBlockIndex = 2, start = { toolUse = { toolUseId = "x", name = "assistant_web_search" } } } } }, nil, result, reasoning, acc)
        q:processChunk({ eventType = { contentBlockDelta = { contentBlockIndex = 2, delta = { toolUse = { input = '{"keywords":"q"}' } } } } }, nil, result, reasoning, acc)
        q:processChunk({ eventType = { contentBlockStop = { contentBlockIndex = 2 } } }, nil, result, reasoning, acc)
        local signal = q:processChunk({ eventType = { messageStop = { stopReason = "tool_use" } } }, nil, result, reasoning, acc)
        assert.equal("TOOLCALLS", signal)
        assert.equal("x", acc.tools[1].id)
        assert.equal('{"keywords":"q"}', acc.tools[1].arguments_parts:tostring())
    end },
}

return helper.runTests("bedrock_handler", tests)
