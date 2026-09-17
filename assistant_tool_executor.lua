--- Tool Executor module for handling tool calls and search API integration
---
--- Centralizes tool execution logic, search API calls, and UI feedback.
--- Provides a clean interface for both stream and non-stream modes.

local logger = require("logger")
local koutil = require("util")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Font = require("ui/font")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local strbuf = require("string.buffer")
local json = require("rapidjson")
local ExtTools = require("assistant_exttools")
local ASUtils = require("assistant_utils")
local json_default = ASUtils.json_default


-- MENU order of search tools
local SEARCH_API_NAMES = {
    "none",
    "builtin",
    "serpapi",
    "tavilyapi",
    "exaapi",
    "searxngapi",
 }

---- Build the messages_to_append list once a search result is available.
---- Called by Querier after it has executed the search API.
----
---- @param tool_call_result  table   the table returned by parseToolCalls (with __is_tool_call)
---- @param search_result     string  markdown text from the search API
---- @return table  list of messages to append to message_history
local function buildToolResultMessages(tool_call_result)

    local raw_assistant = tool_call_result.raw_assistant
    local format = tool_call_result.format
    local results = tool_call_result.search_results

    local keywords = strbuf.new()
    local msgs = {}
    if format == "anthropic" then
        table.insert(msgs, {
            role    = "assistant",
            content = raw_assistant,
        })
        local contents = {}
        for _, result in ipairs(results) do
            table.insert(contents, {
                    type        = "tool_result",
                    tool_use_id = result.tool_call_id,
                    content     = result.search_result,
                })
            keywords:putf("⌗ %s\n\n", result.search_keywords)
        end

        ASUtils.set_attr(msgs[#msgs], "search_keywords", keywords:get())
        table.insert(msgs, {
            role    = "user",
            content = contents,
        })
    elseif format == "gemini" then
        table.insert(msgs, raw_assistant)   -- model turn (role="model", parts=[functionCall…])

        local parts = {}
        for _, result in ipairs(results) do
            table.insert(parts, {
                    functionResponse = {
                        name     = "assistant_web_search",
                        id       = result.tool_call_id,
                        response = { result = result.search_result },
                    },
                })
            keywords:putf("⌗ %s\n\n", result.search_keywords)
        end
        ASUtils.set_attr(msgs[#msgs], "search_keywords", keywords:get())
        table.insert(msgs, { role  = "user", parts = parts, })

    elseif format == "bedrock" then
        table.insert(msgs, raw_assistant)
        local pos = #msgs
        local content = {}
        for _, result in ipairs(results) do
            table.insert(content, { toolResult = {
                toolUseId = result.tool_call_id,
                content = { { text = result.search_result } },
            } })
            keywords:putf("⌗ %s\n\n", result.search_keywords)
        end
        ASUtils.set_attr(msgs[pos], "search_keywords", keywords:get())
        table.insert(msgs, { role = "user", content = content })
    else  -- "openai"
        table.insert(msgs, raw_assistant)
        local pos = #msgs
        for _, result in ipairs(results) do
            table.insert(msgs, {
                role         = "tool",
                tool_call_id = result.tool_call_id,
                content      = result.search_result,
            })
            keywords:putf("⌗ %s\n\n", result.search_keywords)
        end
        ASUtils.set_attr(msgs[pos], "search_keywords", keywords:get())
    end
    return msgs
end


local ToolExecutor = {}
ToolExecutor.SEARCH_API_NAMES = SEARCH_API_NAMES

--- Exposed func to set module variable via Assistant instance
--- @param assistant table Assistant instance
function ToolExecutor.SetSearchAPIConfig(assistant)
    if not assistant then return end
    for api, tool in pairs(ExtTools) do
        local c = assistant.config:getProvider(api)
        if c then
            if c.api_key then tool.api_key = c.api_key end
            if c.base_url then tool.base_url = c.base_url:gsub("/+$", "") end -- trim the ending `/`
        else
            tool.api_key = nil
            tool.base_url = nil -- clear stale if provider deleted
        end
    end
end

function ToolExecutor.IsExtSearch(key)
    return ExtTools[key].is_external
end

function ToolExecutor.ToolToText(key)
    local tool = ExtTools[key]
    if not tool then return "" end
    return tool.name
end


--- Execute a web search using the configured search service.
---
--- Handles UI feedback (keyword search indicator) internally.
---
--- @param keywords           string  search query keywords
--- @param ws_mode            string  "serpapi" | "tavilyapi"
--- @param handler            table   BaseHandler instance with search methods
--- @param tool_round         integer  Notice for the number of rounds the tool called
--- @return boolean success, string|nil result
function ToolExecutor.executeWebSearch(keywords, ws_mode, handler, tool_round)
    if not keywords or #keywords == 0 then
        return false, _("Search keywords are empty.")
    end

    -- Show search indicator
    UIManager:close(handler:resetTrapWidget())
    local keywordmsg = InfoMessage:new({
        face = Font:getFace("smallinfofont"),
        icon = "appbar.search",
        text = ASUtils.bold_format(
            T("<b>%1</b>\n\n<b>⌗ </b>%2", T(_("Searching with %1 ... [%2]"), ToolExecutor.ToolToText(ws_mode), tool_round), keywords)
        ),
    })
    UIManager:show(keywordmsg)

    -- Execute search API based on mode
    local search_ok, search_result
    local API = ExtTools[ws_mode]
    if not API then
        UIManager:close(keywordmsg)
        return false, "Unknown web-search mode: " .. tostring(ws_mode)
    end
    search_ok, search_result = API:SearchKeywords(keywords, keywordmsg)
    if search_ok and type(search_result) == "string" then
        -- remove URLs saving context length
        search_result = search_result:gsub("https?://[%w%-%.%?%&%=%/%~_#:;+,@!$%'()*]+", "")
    end

    UIManager:close(keywordmsg)
    return search_ok, search_result
end

-- ---------------------------------------------------------------------------
-- Public interface: buildRawAssistantForToolCall
-- ---------------------------------------------------------------------------

--- Build a raw_assistant structure for a tool call.
--- This factory method ensures all providers format tool calls consistently.
---
--- @param tool_calls    table  The search tool_call_array
--- @param format        string  "openai" | "anthropic" | "gemini" | "bedrock"
--- @param contents      table|nil   table contains "content", "reasoning_content"
--- @return boolean ok, table|string raw_assistant structure ready for buildToolResultMessages
function ToolExecutor.buildRawAssistantForToolCall(tool_calls, format, contents)
    format = format or "openai"
    
    if format == "anthropic" then
        -- Anthropic expects content_blocks array
        local ret = {}
        if contents and contents.reasoning_content then
            local tc = { type = "thinking", thinking = contents.reasoning_content, }
            if contents.signature then
                tc.signature = contents.signature
            end
            table.insert(ret, tc)
        end
        for tool_index, tc in ipairs(tool_calls) do
            local id, kw, err = ToolExecutor.extractKeywords(tc)
            if err then
                return false, err
            end
            table.insert(ret, {
                    type  = "tool_use",
                    id    = id,
                    name  = "assistant_web_search",
                    input = { keywords = kw },
            })
        end
        return true, ret
    elseif format == "gemini" then
        -- Gemini expects a model turn (role="model")
        local parts = {}
        for _, tc in ipairs(tool_calls) do
            table.insert(parts, {
                    functionCall = {
                        name = "assistant_web_search",
                        id   = tc.tool_call_id,
                        args = { keywords = tc.keywords },
                    },
                })
            if contents and contents.signature then
                parts[#parts].thoughtSignature = contents.signature
            end
        end
        return true, { role  = "model", parts = parts, }
    elseif format == "bedrock" then
        local content = {}
        if contents and type(contents.reasoning_content) == "string" and #contents.reasoning_content > 0 then
            local reasoning_text = { text = contents.reasoning_content }
            if type(contents.signature) == "string" then reasoning_text.signature = contents.signature end
            table.insert(content, { reasoningContent = { reasoningText = reasoning_text } })
        end
        if contents and type(contents.reasoning_redacted_content) == "string" then
            table.insert(content, { reasoningContent = { redactedContent = contents.reasoning_redacted_content } })
        end
        if contents and type(contents.content) == "string" and #contents.content > 0 then
            table.insert(content, { text = contents.content })
        end
        for tool_index, tc in ipairs(tool_calls) do
            local input = tc.input
            if type(input) ~= "table" then
                local ok, decoded = pcall(json.decode, tc.arguments or "{}")
                input = ok and decoded or {}
            end
            table.insert(content, { toolUse = {
                toolUseId = tc.tool_call_id or tc.id,
                name = tc.name or "assistant_web_search",
                input = input,
            } })
        end
        return true, { role = "assistant", content = content }
    else  -- "openai" (and compatible: groq, openrouter, deepseek, mistral, etc.)
        local raw_tool_calls = {}
        for _, tc in ipairs(tool_calls) do
            table.insert(raw_tool_calls, {
                    id        = tc.id,
                    type     = "function",
                    ["function"] = {
                        name      = tc.name,
                        arguments = tc.arguments,
                    },
                })
        end
        local raw = {
            role       = "assistant",
            content    = contents and contents.content,
            tool_calls = raw_tool_calls,
        }
        if contents and contents.reasoning_key and contents.reasoning_content then
            raw[contents.reasoning_key] = contents.reasoning_content
        end
        return true, raw
    end
end


--- Build tool result messages and append them to message history.
---
--- @param message_history    table   conversation history (modified in place)
--- @param tool_call_result   table   tool call descriptor with keywords, raw_assistant, format
--- @return boolean success, string|nil error
function ToolExecutor.appendToolResult(message_history, tool_call_result)

    if not tool_call_result then
        return false, "Invalid tool_call_result structure"
    end

    local tool_msgs = buildToolResultMessages(tool_call_result)
    if not tool_msgs then
        return false, "Failed to build tool result messages"
    end

    for _, msg in ipairs(tool_msgs) do
        table.insert(message_history, msg)
    end

    return true, nil
end

--- Extract keywords from tool call arguments (handles multiple formats).
---
--- Supports:
--- - Gemini: args is already a table
--- - OpenAI/Anthropic: arguments is a JSON string
---
--- @param tool_call       table   single tool call object
--- @return string|nil id, string|nil keywords, string|nil error
function ToolExecutor.extractKeywords(tool_call)
    if type(tool_call) ~= "table" then
        return nil, nil, _("Tool call did not include id.")
    end

    local keywords, id
    local args = koutil.tableGetValue(tool_call, "args")
    local input = koutil.tableGetValue(tool_call, "input")
    local arguments = koutil.tableGetValue(tool_call, "arguments")

    if args ~= nil then
        -- Gemini: args is already a table
        id = koutil.tableGetValue(tool_call, "tool_call_id") or koutil.tableGetValue(tool_call, "id")
        if type(args) == "table" then
            keywords = koutil.tableGetValue(args, "keywords")
        end
    elseif arguments ~= nil then
        -- OpenAI: arguments is a JSON string
        if type(arguments) == "string" then
            local ok_j, decoded = pcall(json.decode, arguments)
            if ok_j and type(decoded) == "table" then
                keywords = json_default(koutil.tableGetValue(decoded, "keywords"))
                    or json_default(koutil.tableGetValue(decoded, "query"))
            end
        end
        id = koutil.tableGetValue(tool_call, "tool_call_id") or koutil.tableGetValue(tool_call, "id")
    elseif input ~= nil then
        -- Anthropic / Bedrock
        id = koutil.tableGetValue(tool_call, "tool_call_id") or koutil.tableGetValue(tool_call, "id")
        if type(input) == "table" then
            keywords = koutil.tableGetValue(input, "keywords")
        end
    end

    if not id then
        return nil, nil, _("Tool call did not include id.")
    end
    if type(keywords) == "table" and #keywords > 0 then
        keywords = keywords[1]
    end
    if type(keywords) ~= "string" or #keywords == 0 then
        return nil, nil, _("Tool call did not include search keywords.")
    end

    return id, keywords, nil
end

--- Get the handler format based on handler name.
---
--- @param handler_name string  name of the handler (anthropic, gemini, openai, etc.)
--- @return string format  "anthropic" | "gemini" | "openai" | "bedrock"
function ToolExecutor.getHandlerFormat(handler_name)
    if handler_name == "anthropic" then
        return "anthropic"
    elseif handler_name == "gemini" then
        return "gemini"
    elseif handler_name == "responses" then
        -- Responses API uses OpenAI-format messages internally for tool-call loop
        return "openai"
    elseif handler_name == "bedrock" then
        return "bedrock"
    else
        -- openai / groq / openrouter / deepseek / mistral / etc.
        return "openai"
    end
end

-- ---------------------------------------------------------------------------
-- Tool-call parsing helpers
-- ---------------------------------------------------------------------------

--- Parse a LLM response and extract tool call details. (for NON-STREAM response)
---
--- Returns: {tool_calls_array}, raw_assistant, direct_content, error
function ToolExecutor.parseToolCallsResponse(responseData, format)
    if format == "anthropic" then
        local content_blocks = responseData.content
        if type(content_blocks) ~= "table" then
            local errmsg = koutil.tableGetValue(responseData, "error", "message")
                        or "Anthropic stage-1: missing content array"
            return nil, nil, nil, errmsg
        end

        local text_block
        local toolcall_blocks = {}
        for _, block in ipairs(content_blocks) do
            if type(block) == "table" then
                if block.type == "text" then
                    text_block = block
                end
                if block.type == "tool_use" and block.input and block.input.keywords then
                    table.insert(toolcall_blocks, block)
                end
            end
        end
        if text_block and #toolcall_blocks == 0 then
            local direct = text_block and text_block.text or nil
            return nil, nil, direct, nil
        end
        return toolcall_blocks, content_blocks, nil, nil

    elseif format == "gemini" then
        local model_content = koutil.tableGetValue(responseData, "candidates", 1, "content")
        if not model_content then
            local err_msg = koutil.tableGetValue(responseData, "error", "message")
                         or koutil.tableGetValue(responseData, "message")
                         or "Gemini: missing content"
            logger.warn("Gemini parse, responseData:", select(2, pcall(json.encode, responseData)):sub(1, 200))
            return nil, nil, nil, err_msg
        end
        local tool_calls = {}
        local text_part
        for _, part in ipairs(model_content.parts) do
            if type(part) == "table" then
                if part.functionCall then 
                    local fn_call   = part.functionCall 
                    table.insert(tool_calls, {
                        tool_call_id = fn_call.id or fn_call.name,
                        args = fn_call.args
                    })
                end
                if part.text         then text_part  = part              end
            end
        end

        if #tool_calls == 0 then
            local direct = text_part and text_part.text or nil
            return nil, model_content, direct, nil
        end
        return tool_calls, model_content, nil, nil

    elseif format == "responses" then
        -- OpenAI Responses API format: parse response.output array
        local output_items = responseData.output
        if type(output_items) ~= "table" then
            local err_msg = koutil.tableGetValue(responseData, "error", "message")
                         or "Responses API stage-1: missing output array"
            return nil, nil, nil, err_msg
        end

        local tool_calls = {}
        local text_parts = {}
        for _, item in ipairs(output_items) do
            if type(item) == "table" then
                if item.type == "function_call" then
                    table.insert(tool_calls, {
                        tool_call_id = item.call_id,
                        name         = item.name,
                        arguments    = item.arguments or "{}",
                    })
                elseif item.type == "message" then
                    local content = item.content
                    if type(content) == "table" then
                        for _, block in ipairs(content) do
                            if block.type == "output_text" and block.text then
                                table.insert(text_parts, block.text)
                            end
                        end
                    elseif type(content) == "string" then
                        table.insert(text_parts, content)
                    end
                end
            end
        end

        -- Build a raw_assistant in OpenAI format for tool-call loop compatibility
        local raw_text = #text_parts > 0 and table.concat(text_parts, "\n\n") or nil
        if #tool_calls == 0 then
            return nil, nil, raw_text, nil
        end

        -- Build raw_assistant in OpenAI format
        local raw_tool_calls = {}
        for _, tc in ipairs(tool_calls) do
            table.insert(raw_tool_calls, {
                id        = tc.tool_call_id,
                type      = "function",
                ["function"] = {
                    name      = tc.name,
                    arguments = tc.arguments,
                },
            })
        end
        local raw_assistant = {
            role       = "assistant",
            content    = raw_text,
            tool_calls = raw_tool_calls,
        }
        return tool_calls, raw_assistant, nil, nil

    elseif format == "bedrock" then
        local content = koutil.tableGetValue(responseData, "output", "message", "content")
        if type(content) ~= "table" then
            return nil, nil, nil, koutil.tableGetValue(responseData, "message")
                or koutil.tableGetValue(responseData, "error", "message")
                or "Bedrock: missing output message content"
        end
        local tool_calls, text_parts = {}, {}
        for _, block in ipairs(content) do
            local tool_use = koutil.tableGetValue(block, "toolUse")
            if type(tool_use) == "table" then
                local input = koutil.tableGetValue(tool_use, "input")
                if type(input) ~= "table" then input = {} end
                table.insert(tool_calls, {
                    tool_call_id = koutil.tableGetValue(tool_use, "toolUseId"),
                    name = koutil.tableGetValue(tool_use, "name"),
                    input = input,
                    arguments = json.encode(input),
                })
            end
            local text = koutil.tableGetValue(block, "text")
            if type(text) == "string" then table.insert(text_parts, text) end
        end
        if #tool_calls == 0 then
            return nil, nil, #text_parts > 0 and table.concat(text_parts) or nil, nil
        end
        return tool_calls, { role = "assistant", content = content }, nil, nil
    else  -- "openai" (default — shared by groq / openrouter / deepseek / mistral / etc.)
        local assistant_message = koutil.tableGetValue(responseData, "choices", 1, "message")
        if not assistant_message then
            local err_msg = koutil.tableGetValue(responseData, "error", "message")
                         or koutil.tableGetValue(responseData, "message")
                         or "OpenAI stage-1: no message in response"
            logger.warn("parse, responseData:", select(2, pcall(json.encode, responseData)):sub(1, 200))
            return nil, nil, nil, err_msg
        end
        local raw_calls = json_default(assistant_message.tool_calls)
        if not raw_calls then
            local direct = json_default(assistant_message.content)
            return nil, nil, direct, nil
        end

        local tool_calls = {}
        for _, tc in ipairs(raw_calls) do
            local arguments_str = koutil.tableGetValue(tc, "function", "arguments") or "{}"
            table.insert(tool_calls, {
                tool_call_id = tc.id,
                name = koutil.tableGetValue(tc, "function", "name"),
                arguments = arguments_str,
            })
        end

        return tool_calls, assistant_message, nil, nil
    end
end

-- ---------------------------------------------------------------------------
-- Tool definition builders
-- ---------------------------------------------------------------------------

--- Build the web_search tool definition in the format required by a given platform.
---
--- format = "openai"     → OpenAI function calling shape
--- format = "anthropic"  → Anthropic tool shape
--- format = "gemini"     → Gemini function_declarations shape
--- format = "bedrock"    → Bedrock toolSpec shape
---
--- @param format string  "openai" | "anthropic" | "gemini" | "bedrock"
--- @return table tool definition
function ToolExecutor.buildExternalSearchToolDef(format)
    local param_schema = {
        type = "object",
        properties = {
            keywords = {
                type = "string",
                description = "Concise search query keywords extracted from the user's question",
            },
        },
        required = { "keywords" },
    }
    local description = [[Search the web for up-to-date information. 
Use this when the user's question requires current or recent information. 
Return exactly one concise search query string.]]

    if format == "anthropic" then
        return {
            name         = "assistant_web_search",
            description  = description,
            input_schema = param_schema,
        }
    elseif format == "gemini" then
        return {
            function_declarations = {
                {
                    name        = "assistant_web_search",
                    description = description,
                    parameters  = param_schema,
                },
            },
        }
    elseif format == "responses" then
        return {
            type        = "function",
            name        = "assistant_web_search",
            description = description,
            parameters  = param_schema,
        }
    elseif format == "bedrock" then
        return {
            toolSpec = {
                name = "assistant_web_search",
                description = description,
                inputSchema = { json = param_schema },
            },
        }
    else  -- "openai"
        return {
            type = "function",
            ["function"] = {
                name        = "assistant_web_search",
                description = description,
                parameters  = param_schema,
            },
        }
    end
end

return ToolExecutor
