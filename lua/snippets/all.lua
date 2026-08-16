-- Postfix snippets for all filetypes
--
-- Provides dot-triggered postfix transformations (e.g., "text.upper" -> "TEXT").
-- These snippets match text before the cursor and transform it in-place.
-- Loaded by LuaSnip's from_lua loader for filetype "all" (applies globally).

--- @type luasnip
local ls = require("luasnip")
--- @type fun(args: table, parent: table): string  Creates computed text from other nodes
local f = ls.function_node
--- @type fun(opts: table, nodes: table): luasnip.Snippet  Creates a postfix-triggered snippet
local postfix = require("luasnip.extras.postfix").postfix

--- @type luasnip.Snippet[]
return {
  -- Postfix ".upper": converts matched text to UPPERCASE
  -- Usage: type "hello.upper" -> expands to "HELLO"
  postfix({ trig = ".upper", name = "Uppercase", desc = "Uppercase(postfix)" }, {
    f(function(_, parent)
      -- parent.snippet.env.POSTFIX_MATCH contains the text before the dot trigger
      return parent.snippet.env.POSTFIX_MATCH:upper()
    end),
  }),

  -- Postfix ".lower": converts matched text to lowercase
  -- Usage: type "HELLO.lower" -> expands to "hello"
  postfix({ trig = ".lower", name = "Lowercase", desc = "Lowercase(postfix)" }, {
    f(function(_, parent)
      -- parent.snippet.env.POSTFIX_MATCH contains the text before the dot trigger
      return parent.snippet.env.POSTFIX_MATCH:lower()
    end),
  }),
}
