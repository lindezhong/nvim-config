-- Shell function snippet with auto-generated docstring
--
-- Provides a "fun" snippet that dynamically generates documentation comments
-- based on the function's argument declarations. As the user edits the argument
-- lines (node 2), the docstring block above the function updates in real-time.
-- Loaded by LuaSnip's from_lua loader for filetype "sh".

--- @type luasnip
local ls = require("luasnip")
--- @type fun(opts: table|string, nodes: table): luasnip.Snippet  Snippet constructor
local s = ls.snippet
--- @type fun(text: string|string[]): luasnip.Node  Static non-editable text node
local t = ls.text_node
--- @type fun(pos: number, default?: string): luasnip.Node  Editable tabstop node
local i = ls.insert_node
--- @type fun(fn: function, deps: table): luasnip.Node  Computed text from dependencies
local f = ls.function_node

--- Parse shell function argument lines and generate docstring comment lines.
--- Extracts variable names and positional parameter numbers from lines like:
---   local name="$1"
---   age="$2"
--- And produces docstring lines like:
---   # :name:$1:
---   # :age:$2:
---
--- @param args_lines string[] Table of lines from insert_node 2 (argument declarations)
--- @return string[]|string  Table of docstring lines with trailing empty string, or "" if no args
local function gen_args_docstring(args_lines)
  --- @type string[]
  local docs = {}
  for _, line in ipairs(args_lines) do
    -- Strip leading/trailing whitespace
    line = vim.trim(line)
    if line ~= "" then
      -- Try matching "local var=$N" or "local var="${N}"" format
      local var, num = line:match('^local%s+(.-)%s*=%s*"?%$%{?(%w+)%}?"?')
      if not var then
        -- Fallback: try matching "var=$N" without local keyword
        var, num = line:match('^(.-)%s*=%s*"?%$%{?(%w+)%}?"?')
      end
      if var and num then
        -- Format as docstring line: # :variable_name:$position_number:
        table.insert(docs, "# :" .. var .. ":$" .. num .. ": ")
      end
    end
  end
  -- Return empty string if no arguments found (renders nothing)
  if #docs == 0 then return "" end
  -- Append empty string to add a trailing newline after docstring block
  docs[#docs + 1] = ""
  return docs
end

--- @type luasnip.Snippet[]
return {
  -- Shell function with auto-generated docstring comments.
  -- Node layout:
  --   node 3: function description (top comment)
  --   node 2: argument declarations (drives docstring generation via function_node)
  --   node 1: function name
  --   node 4: return description
  --   node 5: return docstring detail
  --   node 0: cursor final position (function body)
  s({ trig = "fun", name = "function", desc = "function with docstrings" }, {
    -- Line 1: description comment
    t("# "), i(3, "TODO: Docstring for function."), t({ "", "" }),
    -- Dynamic docstring: regenerates when node 2 (args) changes
    f(function(args)
      return gen_args_docstring(args[1])
    end, { 2 }),
    -- Return value documentation line
    t("# :return:"), i(4), t(": "), i(5, "Docstring"), t({ "", "" }),
    -- Function signature opening
    t("function "), i(1, "function_name"), t({ "() {", "\t" }),
    -- Argument declarations (editable, drives docstring generation)
    i(2, "local name=\"$1\""), t({ "", "\t" }),
    -- Final cursor position inside function body
    i(0), t({ "", "}" }),
  }),
}
