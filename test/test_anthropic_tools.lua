local helper = require("test.helper")
local assert = helper.assert
local Anthropic = require("api_handlers.anthropic")
local ToolExecutor = require("assistant_tool_executor")

local function handler()
    return Anthropic:new({
        base_url = "https://api.anthropic.com/v1", model = "claude-test", api_key = "key",
        additional_parameters = {},
    })
end

local tests = {
    { name = "preserves configured native tools when adding book search", fn = function()
        local h = handler()
        h.additional_parameters.tools = { { type = "web_search_20250305", name = "web_search" } }
        local body = h:buildRequestBody({ { role = "user", content = "Question" } }, {
            { name = "assistant_search_book", input_schema = { type = "object" } },
        }, false)
        assert.equal(2, #body.tools)
        assert.equal("web_search", body.tools[1].name)
        assert.equal("assistant_search_book", body.tools[2].name)
    end },
    { name = "keeps tool calls when the response includes a text preamble", fn = function()
        local result = handler():parseToolCalls({ content = {
            { type = "text", text = "I will check." },
            { type = "tool_use", id = "book-1", name = "assistant_search_book", input = { query = "signal" } },
        } }, "anthropic")
        assert.isTrue(result.__is_tool_call)
        assert.equal("assistant_search_book", result.tool_calls[1].name)
    end },
    { name = "replays streamed text before a tool call", fn = function()
        local ok, raw = ToolExecutor.buildRawAssistantForToolCall({ {
            id = "book-1", name = "assistant_search_book", arguments = '{"query":"signal"}',
        } }, "anthropic", { content = "I will check." })
        assert.isTrue(ok)
        assert.equal("text", raw[1].type)
        assert.equal("I will check.", raw[1].text)
        assert.equal("tool_use", raw[2].type)
    end },
}

return helper.runTests("anthropic_tools", tests)
