-- nvim-cmp source adapter for StarDict dictionaries.
-- Thin layer over lua/dict.lua (singleton StarDict reader).

local dict = require("dict")

local source = {}

source.get_keyword_pattern = function()
  return [[\a\+]]
end

source.is_available = function()
  return dict:is_ready()
end

--- @param params cmp.SourceCompletionApiParams
--- @param callback fun(response: lsp.CompletionList)
source.complete = function(self, params, callback)
  local prefix = params.context.cursor_before_line:sub(params.offset)
  if #prefix < 1 then
    callback({ items = {}, isIncomplete = true })
    return
  end

  local results = dict:search(prefix)
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

  callback({ items = items, isIncomplete = true })
end

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
