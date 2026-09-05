-- nvim-cmp source adapter for StarDict dictionaries.
-- Thin layer over lua/dict.lua (singleton StarDict reader).
--
-- Fuzzy matching: always returns isIncomplete=true so cmp re-queries every
-- keystroke (prevents stale cache when user deletes and retypes at same offset).
-- Source-side caching: when prefix search yields fewer than FUZZY_THRESHOLD
-- results, subsequent keystrokes that extend the cached prefix skip the binary
-- search and return cached items directly. cmp's built-in fuzzy matcher then
-- handles typo tolerance (e.g. "helo" still finds "hello").
--
-- vim.g.dict_fuzzy_threshold (default 1000): when result count is below this
-- value, source caches results internally. Higher values improve typo coverage
-- for shorter prefixes but increase per-keystroke fuzzy-filter cost.

local dict = require("dict")

local source = {}
source._cache_prefix = nil
source._cache_items = nil

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
--- Always returns isIncomplete=true so cmp re-queries every keystroke (avoids
--- stale cache when the user deletes and retypes a different word at the same
--- offset). Source-side caching kicks in when result count < FUZZY_THRESHOLD:
--- subsequent keystrokes that extend the cached prefix reuse the cached items,
--- and cmp's fuzzy matcher handles typo tolerance on the cached set.
--- @param params cmp.SourceCompletionApiParams
--- @param callback fun(response: lsp.CompletionList)
source.complete = function(self, params, callback)
  local prefix = params.context.cursor_before_line:sub(params.offset)
  if #prefix < 1 then
    self._cache_prefix = nil
    self._cache_items = nil
    callback({ items = {}, isIncomplete = true })
    return
  end

  local prefix_lower = prefix:lower()

  if self._cache_items and self._cache_prefix
      and vim.startswith(prefix_lower, self._cache_prefix) then
    callback({ items = self._cache_items, isIncomplete = true })
    return
  end

  local results = dict:search(prefix, FUZZY_THRESHOLD)
  local items = {}

  for _, r in ipairs(results) do
    items[#items + 1] = {
      label = r.word,
      insertText = prefix .. r.word:sub(#prefix + 1),
      filterText = r.word:lower(),
      data = { idx = r.index },
    }
  end

  if #results > 0 and #results < FUZZY_THRESHOLD then
    self._cache_prefix = prefix_lower
    self._cache_items = items
  else
    self._cache_prefix = nil
    self._cache_items = nil
  end

  callback({ items = items, isIncomplete = true })
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
