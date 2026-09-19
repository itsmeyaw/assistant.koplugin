-- test_error_message.lua
-- Tests for the shared ASUtils.extractErrorMessage helper (assistant_utils.lua):
-- single implementation every module must use instead of hand-rolled chains.
local helper = require("test.helper")
local assert = helper.assert
local ASUtils = helper.ASUtils

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {
    test("fetchJSON preserves the transport error detail", function()
        local original_http_request = ASUtils.httpRequest
        local Trapper = require("ui/trapper")
        local original_subprocess = Trapper.dismissableRunInSubprocess
        ASUtils.httpRequest = function()
            return false, "REQUEST_TIMEOUT", "Request interrupted/timed out"
        end
        Trapper.dismissableRunInSubprocess = function(_, fn)
            return true, fn()
        end
        local parsed, err = helper.originalFetchJSON("https://example.com")
        ASUtils.httpRequest = original_http_request
        Trapper.dismissableRunInSubprocess = original_subprocess

        assert.equal(parsed, nil)
        assert.equal(err, "Request interrupted/timed out")
    end),

    test("extractErrorMessage: error.message wins", function()
        local d = ASUtils.extractErrorMessage('{"error":{"message":"boom"},"message":"ignored"}')
        assert.equal(d, "boom")
    end),

    test("extractErrorMessage: flat string error", function()
        assert.equal(ASUtils.extractErrorMessage('{"error":"flat bad"}'), "flat bad")
    end),

    test("extractErrorMessage: unwraps detail.error.message", function()
        local body = '{"detail":{"error":{"message":"concurrency limit (80)","type":"rate_limit_error"}}}'
        assert.equal(ASUtils.extractErrorMessage(body), "concurrency limit (80)")
    end),

    test("extractErrorMessage: unwraps detail.message and string detail", function()
        assert.equal(ASUtils.extractErrorMessage('{"detail":{"message":"slow"}}'), "slow")
        assert.equal(ASUtils.extractErrorMessage('{"detail":"just slow"}'), "just slow")
    end),

    test("extractErrorMessage: bare message", function()
        assert.equal(ASUtils.extractErrorMessage('{"message":"bare"}'), "bare")
    end),

    test("extractErrorMessage: accepts an already-decoded table", function()
        assert.equal(ASUtils.extractErrorMessage({ error = { message = "tab" } }), "tab")
        assert.equal(ASUtils.extractErrorMessage({ detail = { error = { message = "deep" } } }), "deep")
    end),

    test("extractErrorMessage: nil/empty/garbage returns nil", function()
        assert.equal(ASUtils.extractErrorMessage(nil), nil)
        assert.equal(ASUtils.extractErrorMessage(""), nil)
        assert.equal(ASUtils.extractErrorMessage("not json"), nil)
        assert.equal(ASUtils.extractErrorMessage('{"ok":true}'), nil)
        assert.equal(ASUtils.extractErrorMessage('{"error":{"code":429}}'), nil)
    end),

    test("extractErrorMessage: numeric message becomes string", function()
        assert.equal(ASUtils.extractErrorMessage('{"error":{"message":429}}'), "429")
    end),
}

return helper.runTests("assistant_error_message", tests)
