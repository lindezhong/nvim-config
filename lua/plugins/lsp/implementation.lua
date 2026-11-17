-- Implementation: go to implementation of the interface/abstract under cursor.
--
-- Behavior mirrors definition.lua:
--   - No implementation found: show notification
--   - Single implementation: jump directly
--   - Multiple implementations: open peekview

local peekview = require("widgets.peekview")
local goto_loc = require("plugins.lsp.goto")

local function open_implementation()
  local source_win = vim.api.nvim_get_current_win()
  local word = vim.fn.expand("<cword>")

  vim.lsp.buf.implementation({
    on_list = function(options)
      local items = options.items
      if #items == 0 then
        vim.notify("No implementation found", vim.log.levels.INFO)
        return
      end

      if #items == 1 then
        goto_loc.jump_to(source_win, items[1])
        return
      end

      peekview.open({
        items = items,
        title = "Implementations (" .. #items .. ")",
        word = word,
        source_win = source_win,
        mode = vim.g.definition_mode or "float",
        layout = vim.g.definition_layout,
        keys = vim.g.definition_keys,
        highlights = {
          float = "DefinitionFloat",
          select = "DefinitionSelect",
          preview = "DefinitionPreview",
        },
      })
    end,
  })
end

return { open = open_implementation }
