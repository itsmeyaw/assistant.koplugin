local puremd = require("apps/filemanager/lib/md")

-- Convert pipe-table <p> blocks that markdown.lua passes through verbatim into
-- proper <table> HTML that CRE can render.
local function render_tables(html)
    return (html:gsub("<p>([%s%S]-)</p>", function(block)
        if not block:match("^%s*|") then
            return nil
        end

        local rows = {}
        for line in block:gmatch("[^\r\n]+") do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed ~= "" then
                rows[#rows + 1] = trimmed
            end
        end

        if #rows < 3 then return nil end

        if not rows[2]:match("^|?[%s%-:|]+|$") then return nil end

        local out = { "<table>" }

        for i, row in ipairs(rows) do
            if i == 2 then
                -- skip separator row
            else
                local tag = (i == 1) and "th" or "td"
                local inner = row:match("^|?(.+)|?$") or ""
                out[#out + 1] = "<tr>"
                for cell in (inner .. "|"):gmatch("(.-)|") do
                    local c = cell:match("^%s*(.-)%s*$")
                    if c ~= "" then
                        out[#out + 1] = string.format("<%s>%s</%s>", tag, c, tag)
                    end
                end
                out[#out + 1] = "</tr>"
            end
        end

        out[#out + 1] = "</table>"
        return table.concat(out)
    end))
end

return function(text)
    return render_tables(puremd(text))
end
