-- nvim-cmp source adapter for StarDict dictionaries.
-- Thin layer over lua/dict.lua (singleton StarDict reader).
--
-- Fuzzy matching: when the prefix search result count is below the threshold,
-- isIncomplete is set to false so that cmp caches the candidates and applies
-- its own fuzzy matching on subsequent keystrokes. This allows typo tolerance
-- (e.g. "helo" still finds "hello") as long as the error occurs after the
-- caching point.
--
-- vim.g.dict_fuzzy_threshold (default 1000): maximum candidate count at which
-- the source switches from isIncomplete=true (re-query each keystroke) to
-- isIncomplete=false (cmp caches and fuzzy-filters). Higher values improve
-- typo coverage for short prefixes but increase per-keystroke filter cost.

local dict = require("dict")

local source = {}

local FUZZY_THRESHOLD = vim.g.dict_fuzzy_threshold or 1000

--- Keyword pattern: match one or more alphabetic characters.
source.get_keyword_pattern = function()
  return [[\a\+]]
end

--- Source is available once the StarDict index is fully loaded.
source.is_available = function()
  return dict:is_ready()
end

--- Return completion candidates for the current prefix.
--- Results are capped at FUZZY_THRESHOLD; when the full set fits within that
--- limit, isIncomplete=false lets cmp cache and fuzzy-filter on later input.
--- @param params cmp.SourceCompletionApiParams
--- @param callback fun(response: lsp.CompletionList)
source.complete = function(self, params, callback)
  local prefix = params.context.cursor_before_line:sub(params.offset)
  if #prefix < 1 then
    callback({ items = {}, isIncomplete = true })
    return
  end

  local results = dict:search(prefix, FUZZY_THRESHOLD)
  local items = {}

  for _, r in ipairs(results) do
    local insert_text = prefix .. r.word:sub(#prefix + 1)
    items[#items + 1] = {
      label = r.word,
      insertText = insert_text,
      filterText = r.word:lower(),
      data = { idx = r.index },
    }
  end

  local is_incomplete = #results == 0 or #results >= FUZZY_THRESHOLD
  callback({ items = items, isIncomplete = is_incomplete })
end

--- Lazily fetch the full definition when the user highlights a candidate.
--- @param item lsp.CompletionItem
--- @param callback fun(item: lsp.CompletionItem)
source.resolve = function(self, item, callback)
  local idx = item.data and item.data.idx
  if not idx then
    callback(item)
    return
  end

  local text = dict:read_definition(idx)
  if #text == 0 then
    callback(item)
    return
  end

  item.documentation = {
    kind = "markdown",
    value = text,
  }

  callback(item)
end

return source
