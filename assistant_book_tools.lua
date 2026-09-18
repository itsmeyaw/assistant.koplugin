-- Read-only, bounded book tools for native LLM function calling.
local _ = require("assistant_gettext")
local util = require("util")
local ASUtils = require("assistant_utils")

local BookTools = {}

local DEFAULT_MAX_RESULTS = 5
local MAX_RESULTS = 10
local DEFAULT_CONTEXT_WORDS = 60
local MAX_CONTEXT_WORDS = 120
local MAX_QUERY_BYTES = 500

local function pageTextToString(value)
    if type(value) == "string" then
        return value
    elseif type(value) == "table" then
        local texts = {}
        for block_index, block in ipairs(value) do
            if type(block) == "table" then
                for span_index = 1, #block do
                    local span = block[span_index]
                    if type(span) == "table" and type(span.word) == "string" then
                        texts[#texts + 1] = span.word
                    end
                end
            end
        end
        return table.concat(texts, " ")
    end
    return ""
end

local function collapseWhitespace(text)
    if type(text) ~= "string" then return "" end
    return text:gsub("\194\160", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
end

local function normalize(text)
    return collapseWhitespace(text):lower()
end

local function positiveInteger(value, default, maximum)
    value = tonumber(value)
    if not value then return default end
    return math.max(1, math.min(maximum, math.floor(value)))
end

local function excerptAround(text, start_pos, end_pos, context_words)
    local words = {}
    local match_word
    for word_start, word, after_word in text:gmatch("()(%S+)()") do
        words[#words + 1] = { start_pos = word_start, end_pos = after_word - 1 }
        if word_start <= end_pos and after_word > start_pos then
            match_word = #words
        end
    end
    if not match_word then return "" end

    local first = math.max(1, match_word - context_words)
    local last = math.min(#words, match_word + context_words)
    return text:sub(words[first].start_pos, words[last].end_pos)
end

local function getPageText(ui, page, total_pages)
    local document = ui.document
    if document.info and document.info.has_pages then
        local ok, text = pcall(function() return document:getPageText(page) end)
        return ok and pageTextToString(text) or ""
    end

    local ok, text = pcall(function()
        local start_xp = document:getPageXPointer(page)
        local end_xp = page < total_pages and document:getPageXPointer(page + 1)
            or ASUtils.getDocumentEndXPointer(ui)
        if not start_xp or not end_xp then return "" end
        return document:getTextFromXPointers(start_xp, end_xp) or ""
    end)
    return ok and text or ""
end

--- Search every page for a literal case- and whitespace-insensitive query.
--- Results remain small so a tool response cannot consume the conversation.
function BookTools.search(ui, args)
    args = type(args) == "table" and args or {}
    local query = normalize(args.query)
    if query == "" then
        return nil, _("Book search query is empty.")
    end
    if #query > MAX_QUERY_BYTES then
        return nil, _("Book search query is too long.")
    end
    if not ui or not ui.document then
        return nil, _("Book text is unavailable.")
    end

    local ok, total_pages = pcall(function() return ui.document:getPageCount() end)
    if not ok or type(total_pages) ~= "number" or total_pages < 1 then
        return nil, _("Book pages are unavailable.")
    end

    local max_results = positiveInteger(args.max_results, DEFAULT_MAX_RESULTS, MAX_RESULTS)
    local context_words = positiveInteger(args.context_words, DEFAULT_CONTEXT_WORDS, MAX_CONTEXT_WORDS)
    local saved_xp
    local saved_selection
    if not (ui.document.info and ui.document.info.has_pages) then
        pcall(function() saved_xp = ui.document:getXPointer() end)
        if ui.highlight and ui.highlight.selected_text and ui.highlight.selected_text.pos0
            and ui.highlight.selected_text.pos1 then
            saved_selection = util.tableDeepCopy(ui.highlight.selected_text)
        end
    end

    local results = {}
    local previous_tail = ""
    local previous_page
    for page = 1, total_pages do
        local page_text = collapseWhitespace(getPageText(ui, page, total_pages))
        local prefix = previous_tail ~= "" and previous_tail .. " " or ""
        local text = prefix .. page_text
        local normalized_text = text:lower()
        local search_from = 1
        while #results < max_results do
            local start_pos, end_pos = normalized_text:find(query, search_from, true)
            if not start_pos then break end
            -- Matches contained in the previous-page suffix were already emitted.
            if end_pos > #prefix then
                local excerpt = excerptAround(text, start_pos, end_pos, context_words)
                local result_page = start_pos <= #prefix and previous_page or page
                local label = string.format("%s %d", _("Page"), result_page)
                local chapter
                if ui.toc then
                    pcall(function() chapter = ui.toc:getTocTitleByPage(result_page) end)
                end
                if type(chapter) == "string" and chapter ~= "" then
                    label = label .. " - " .. chapter
                end
                if excerpt ~= "" then
                    results[#results + 1] = string.format("[%s]\n%s", label, excerpt)
                end
            end
            search_from = end_pos + 1
        end
        if #results >= max_results then break end
        previous_tail = ASUtils.truncateToTailUtf8Safe(page_text, MAX_QUERY_BYTES)
        previous_page = page
    end

    if saved_xp then
        pcall(function() ui.document:gotoXPointer(saved_xp) end)
    end
    if saved_selection then
        pcall(function()
            ui.highlight.selected_text = saved_selection
            if type(saved_selection.pos0) == "string" and type(saved_selection.pos1) == "string" then
                ui.document:getTextFromXPointers(saved_selection.pos0, saved_selection.pos1, true)
            end
        end)
    end
    if #results == 0 then
        return _("No matches found in the book.")
    end
    return table.concat(results, "\n\n")
end

return BookTools
