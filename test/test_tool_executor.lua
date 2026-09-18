local helper = require("test.helper")
local assert = helper.assert
local ToolExecutor = require("assistant_tool_executor")

local tests = {
    { name = "offers the book search tool without web search", fn = function()
        local tools = ToolExecutor.buildTools("openai", "none", true)
        assert.equal(1, #tools)
        assert.equal("assistant_search_book", tools[1]["function"].name)
        assert.equal("query", tools[1]["function"].parameters.required[1])
    end },
    { name = "combines local and external Gemini declarations", fn = function()
        local tool = ToolExecutor.buildTools("gemini", "tavilyapi", true)
        assert.equal(2, #tool.function_declarations)
        assert.equal("assistant_search_book", tool.function_declarations[1].name)
        assert.equal("assistant_web_search", tool.function_declarations[2].name)
    end },
    { name = "does not offer functions unless requested", fn = function()
        assert.equal(nil, ToolExecutor.buildTools("openai", "none", false))
    end },
    { name = "normalizes local book tool calls", fn = function()
        local id, name, args = ToolExecutor.extractToolCall({
            tool_call_id = "book-1",
            name = "assistant_search_book",
            arguments = '{"query":"Dune","max_results":2}',
        })
        assert.equal("book-1", id)
        assert.equal("assistant_search_book", name)
        assert.equal("Dune", args.query)
        assert.equal(2, args.max_results)
    end },
    { name = "replays local tool results in OpenAI history", fn = function()
        local history = {}
        local ok = ToolExecutor.appendToolResult(history, {
            format = "openai",
            raw_assistant = { role = "assistant", tool_calls = {} },
            tool_results = {
                { tool_call_id = "book-1", tool_name = "assistant_search_book",
                    tool_result = "[Page 4]\\nA match.", tool_summary = "match" },
            },
        })
        assert.isTrue(ok)
        assert.equal("tool", history[2].role)
        assert.equal("book-1", history[2].tool_call_id)
        assert.equal("[Page 4]\\nA match.", history[2].content)
    end },
}

return helper.runTests("tool_executor", tests)
