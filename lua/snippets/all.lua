-- Postfix snippets for all filetypes
--
-- Provides dot-triggered postfix transformations (e.g., "text.upper" -> "TEXT").
-- These snippets match text before the cursor and transform it in-place.
-- Loaded by LuaSnip's from_lua loader for filetype "all" (applies globally).
--
-- Triggers are "upper"/"lower" (without leading dot) so that the completion
-- menu does NOT pop up on typing the dot itself — only after typing the first
-- letter of the command.  show_condition ensures the items appear only when
-- the cursor follows a "word." pattern; match_pattern captures the prefix
-- including the trailing dot, which is stripped at expansion time.

--- @type luasnip
local ls = require("luasnip")
--- @type fun(args: table, parent: table): string  Creates computed text from other nodes
local f = ls.function_node
--- @type fun(opts: table, nodes: table): luasnip.Snippet  Creates a postfix-triggered snippet
local postfix = require("luasnip.extras.postfix").postfix

--- Only show postfix snippets when cursor follows a "word." pattern
local function after_dot(line_to_cursor)
  return line_to_cursor:match("[%w%.%_%-]+%.[%w]*$") ~= nil
end

--- @type luasnip.Snippet[]
return {
  -- Postfix "upper": converts matched text to UPPERCASE
  -- Usage: type "hello.upper" -> expands to "HELLO"
  postfix({
    trig = "upper",
    match_pattern = "[%w%.%_%-]+%.$",
    show_condition = after_dot,
    name = "Uppercase",
    desc = "Uppercase(postfix)",
  }, {
    f(function(_, parent)
      -- parent.snippet.env.POSTFIX_MATCH contains the text before the trigger
      -- including the trailing dot, which we strip before transforming
      return parent.snippet.env.POSTFIX_MATCH:gsub("%.$", ""):upper()
    end),
  }),

  -- Postfix "lower": converts matched text to lowercase
  -- Usage: type "HELLO.lower" -> expands to "hello"
  postfix({
    trig = "lower",
    match_pattern = "[%w%.%_%-]+%.$",
    show_condition = after_dot,
    name = "Lowercase",
    desc = "Lowercase(postfix)",
  }, {
    f(function(_, parent)
      -- parent.snippet.env.POSTFIX_MATCH contains the text before the trigger
      -- including the trailing dot, which we strip before transforming
      return parent.snippet.env.POSTFIX_MATCH:gsub("%.$", ""):lower()
    end),
  }),
}
