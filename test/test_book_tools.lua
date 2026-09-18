local helper = require("test.helper")
local assert = helper.assert
local BookTools = require("assistant_book_tools")

local function make_ui(pages)
    return {
        document = {
            info = { has_pages = true },
            getPageCount = function() return #pages end,
            getPageText = function(_, page) return pages[page] end,
        },
        toc = {
            getTocTitleByPage = function(_, page)
                return page == 2 and "Chapter Two" or nil
            end,
        },
    }
end

local tests = {
    { name = "searches the entire book with bounded page-labelled excerpts", fn = function()
        local result = BookTools.search(make_ui({
            "A quiet opening with no target.",
            "Before the lost   RING appeared, everyone waited. Afterwards, the ring vanished.",
            "The final ring was found at dawn.",
        }), { query = "lost ring", max_results = 2, context_words = 2 })

        assert.matches(result, "Page 2 %- Chapter Two")
        assert.matches(result, "lost RING appeared")
        assert.equal(nil, result:find("Page 3", 1, true))
    end },
    { name = "caps results and accepts whitespace-insensitive queries", fn = function()
        local result = BookTools.search(make_ui({
            "Alpha beta gamma.",
            "ALPHA\nbeta delta.",
            "alpha beta epsilon.",
        }), { query = " alpha   beta ", max_results = 1, context_words = 1 })

        assert.matches(result, "Page 1")
        assert.equal(nil, result:find("Page 2", 1, true))
    end },
    { name = "finds a phrase split across page boundaries", fn = function()
        local result = BookTools.search(make_ui({
            "The signal was almost",
            " lost beneath the noise.",
        }), { query = "almost lost", max_results = 1, context_words = 2 })

        assert.matches(result, "Page 1")
        assert.matches(result, "almost lost")
    end },
    { name = "rejects empty and malformed queries", fn = function()
        local result, err = BookTools.search(make_ui({ "Any text." }), { query = "   " })
        assert.equal(nil, result)
        assert.matches(err, "query")
    end },
}

return helper.runTests("book_tools", tests)
