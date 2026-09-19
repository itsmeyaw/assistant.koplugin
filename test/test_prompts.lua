-- test_prompts.lua
-- Tests for the Phase-1 prompt-context feature:
--   * built-in prompt flag defaults (use_book_context)
--   * deep-merge override semantics via M.getMergedPrompts
--   * inline copy of AssistantDialog:_buildBookContextMessage content assembly
--   * ASUtils.set_attr/get_attr roundtrip for is_context metadata
-- Tests for the Phase-2 nearby-page-text feature:
--   * ASUtils.getPageRangeText availability guards
--   * inline copy of the pure budget-assembly helper (assemblePageContext)
--   * inline copy of the page-text injection decision logic
local helper = require("test.helper")
local assert = helper.assert
local M = require("assistant_prompts")
local ASUtils = helper.ASUtils

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {

    -- =========================================================================
    -- 1. Built-in flag defaults
    -- =========================================================================

    test("builtin_prompts: all 13 keys exist", function()
        local keys = {
            "term_xray", "dictionary", "quick_note", "vocabulary", "grammar",
            "translate", "summarize", "simplify", "key_points", "ELI5",
            "explain", "historical_context", "wikipedia",
        }
        for _, key in ipairs(keys) do
            assert.notNil(M.builtin_prompts[key], "builtin_prompts." .. key .. " should exist")
        end
    end),

    test("builtin_prompts: use_book_context == true on the 5 expected keys", function()
        local true_keys = { "summarize", "key_points", "ELI5", "explain", "historical_context" }
        for _, key in ipairs(true_keys) do
            assert.equal(M.builtin_prompts[key].use_book_context, true,
                key .. ".use_book_context should be true")
        end
    end),

    test("builtin_prompts: use_book_context == false on the other 8 keys", function()
        local false_keys = {
            "term_xray", "dictionary", "quick_note", "vocabulary", "grammar",
            "translate", "simplify", "wikipedia",
        }
        for _, key in ipairs(false_keys) do
            assert.equal(M.builtin_prompts[key].use_book_context, false,
                key .. ".use_book_context should be false")
        end
    end),

    -- =========================================================================
    -- 2. Deep-merge override semantics
    -- =========================================================================

    test("getMergedPrompts: field-level merge (explain flipped to false)", function()
        M.invalidateCache()
        local merged = M.getMergedPrompts({ explain = { use_book_context = false } })
        assert.equal(merged.explain.use_book_context, false,
            "explain.use_book_context should be overridden to false")
        -- other fields preserved (field-level merge, not whole-entry replace)
        assert.notNil(merged.explain.text, "explain.text should be preserved")
        assert.notNil(merged.explain.order, "explain.order should be preserved")
    end),

    test("getMergedPrompts: flip default-false vocabulary up to true", function()
        M.invalidateCache()
        local merged = M.getMergedPrompts({ vocabulary = { use_book_context = true } })
        assert.equal(merged.vocabulary.use_book_context, true,
            "vocabulary.use_book_context should be flipped to true")
        assert.notNil(merged.vocabulary.text, "vocabulary.text should be preserved")
    end),

    test("getMergedPrompts: nil conf after invalidateCache returns built-in defaults", function()
        M.invalidateCache()
        local merged = M.getMergedPrompts(nil)
        assert.equal(merged.summarize.use_book_context, true, "summarize should default true")
        assert.equal(merged.vocabulary.use_book_context, false, "vocabulary should default false")
        assert.equal(merged.explain.use_book_context, true, "explain should default true")
    end),

    -- =========================================================================
    -- 3. ASUtils.set_attr/get_attr roundtrip (is_context metadata)
    -- =========================================================================

    test("ASUtils.set_attr/get_attr roundtrip (is_context=true)", function()
        local msg = { role = "user", content = "hi" }
        ASUtils.set_attr(msg, "is_context", true)
        assert.isTrue(ASUtils.get_attr(msg, "is_context") == true,
            "is_context should roundtrip as true")
    end),

    -- =========================================================================
    -- 4. Phase-2: getPageRangeText availability guards (real module)
    -- =========================================================================

    test("getPageRangeText: nil ui returns empty string", function()
        assert.equal(ASUtils.getPageRangeText(nil, 1, 1, 6000), "",
            "nil ui should yield empty string")
    end),

    test("getPageRangeText: ui without document returns empty string", function()
        assert.equal(ASUtils.getPageRangeText({}, 1, 1, 6000), "",
            "missing ui.document should yield empty string")
    end),

    test("getPageRangeText: document without selection pos0 returns empty string", function()
        assert.equal(ASUtils.getPageRangeText({ document = {} }, 1, 1, 6000), "",
            "missing selection pos0 should yield empty string")
    end),
}

-- =========================================================================
-- 5. AI Dictionary output sections / presets
-- =========================================================================

local dict_tests = {
    test("dict_presets: standard/full exact lists and no concise preset", function()
        assert.equal(M.dict_presets.concise, nil, "concise is no longer a preset")

        assert.equal(#M.dict_presets.standard, 3, "standard should have 3 sections")
        assert.equal(M.dict_presets.standard[1], "meaning")
        assert.equal(M.dict_presets.standard[2], "translation")
        assert.equal(M.dict_presets.standard[3], "synonyms")

        local full = M.dict_presets.full
        assert.equal(#full, 6, "full should have 6 sections")
        assert.equal(full[1], "meaning")
        assert.equal(full[2], "translation")
        assert.equal(full[3], "synonyms")
        assert.equal(full[4], "word_form")
        assert.equal(full[5], "example")
        assert.equal(full[6], "origin")
    end),

    test("build_dict_prompt: standard has three sections and omits the rest", function()
        local p = M.build_dict_prompt(M.dict_presets.standard)
        assert.matches(p, "Meaning & Usage")
        assert.matches(p, "Translation")
        assert.matches(p, "Synonyms")
        assert.notMatches(p, "Word Form & Lemma")
        assert.notMatches(p, "Example")
        assert.notMatches(p, "Word Origin")
    end),

    test("build_dict_prompt: full has all six sections and word-form rules", function()
        local p = M.build_dict_prompt(M.dict_presets.full)
        assert.matches(p, "Meaning & Usage")
        assert.matches(p, "Translation")
        assert.matches(p, "Synonyms")
        assert.matches(p, "Word Form & Lemma")
        assert.matches(p, "Example")
        assert.matches(p, "Word Origin")
        assert.matches(p, "Word%-Form Analysis %(required%)")
    end),

    test("build_dict_prompt: concise omits word-form task and analysis rules", function()
        local p = M.build_dict_prompt({ "meaning", "translation" })
        assert.notMatches(p, "Word%-Form Analysis %(required%)")
        assert.matches(p, "## Task: Book%-Aware Dictionary")
        assert.notMatches(p, "and Word%-Form Analysis")
    end),

    test("build_dict_prompt: keeps caller placeholders", function()
        local p = M.build_dict_prompt(M.dict_presets.standard)
        assert.matches(p, "{word}")
        assert.matches(p, "{context}")
        assert.matches(p, "{language}")
    end),

    test("build_dict_prompt: bolds the queried headword everywhere", function()
        local p = M.build_dict_prompt(M.dict_presets.standard)
        assert.matches(p, "%*%*Headword in Bold%*%*")
        assert.matches(p, "%*%*{word}%*%*")
    end),

    test("build_dict_prompt: headword exception only when translation is enabled", function()
        local with_translation = M.build_dict_prompt({ "meaning", "translation" })
        assert.matches(with_translation, "in the Translation section")
        local without_translation = M.build_dict_prompt({ "meaning", "synonyms" })
        assert.notMatches(without_translation, "in the Translation section")
    end),

    test("presetToMap: standard maps meaning+translation+synonyms", function()
        local map = M.presetToMap("standard")
        assert.equal(map.meaning, true)
        assert.equal(map.translation, true)
        assert.equal(map.synonyms, true)
        assert.equal(map.word_form, nil)
    end),

    test("resolveDictSections: default returns standard", function()
        local store = {}
        local settings = { readSetting = function(self, k, d) return store[k] or d end }
        local result = M.resolveDictSections(settings)
        assert.equal(#result, 3)
        assert.equal(result[1], "meaning")
        assert.equal(result[2], "translation")
        assert.equal(result[3], "synonyms")
    end),

    test("resolveDictSections: preset full returns full", function()
        local store = { dict_output_preset = "full" }
        local settings = { readSetting = function(self, k, d) return store[k] or d end }
        local result = M.resolveDictSections(settings)
        assert.equal(#result, 6)
        assert.equal(result[4], "word_form")
        assert.equal(result[5], "example")
        assert.equal(result[6], "origin")
    end),

    test("resolveDictSections: custom reads the saved section map in order", function()
        local store = {
            dict_output_preset = "custom",
            dict_output_sections = { meaning = true },
        }
        local settings = { readSetting = function(self, k, d) return store[k] or d end }
        local result = M.resolveDictSections(settings)
        assert.equal(#result, 1)
        assert.equal(result[1], "meaning")
    end),

    test("resolveDictSections: custom with empty map falls back to standard", function()
        local store = {
            dict_output_preset = "custom",
            dict_output_sections = {},
        }
        local settings = { readSetting = function(self, k, d) return store[k] or d end }
        local result = M.resolveDictSections(settings)
        assert.equal(#result, 3)
        assert.equal(result[1], "meaning")
        assert.equal(result[2], "translation")
        assert.equal(result[3], "synonyms")
    end),

    test("build_dict_prompt: concise opts swaps Book-Awareness for Brevity", function()
        local p = M.build_dict_prompt({ "meaning", "translation" }, { concise = true })
        assert.matches(p, "%*%*Brevity%*%*")
        assert.notMatches(p, "Book%-Awareness")
    end),

    test("build_dict_prompt: concise opts uses the short meaning body", function()
        local p = M.build_dict_prompt({ "meaning", "translation" }, { concise = true })
        assert.matches(p, "in one sentence")
        assert.notMatches(p, "what it suggests about the characters")
    end),

    test("build_dict_prompt: standard without opts keeps the full meaning body", function()
        local p = M.build_dict_prompt(M.dict_presets.standard)
        assert.matches(p, "Book%-Awareness")
        assert.notMatches(p, "%*%*Brevity%*%*")
        assert.matches(p, "what it suggests about the characters")
    end),

    test("build_dict_prompt: full with concise opts keeps sections but Brevity rules", function()
        local p = M.build_dict_prompt(M.dict_presets.full, { concise = true })
        assert.matches(p, "%*%*Brevity%*%*")
        assert.notMatches(p, "Book%-Awareness")
        assert.matches(p, "Word Form & Lemma")
    end),
}

for _, t in ipairs(dict_tests) do
    table.insert(tests, t)
end

return helper.runTests("assistant_prompts.lua", tests)
