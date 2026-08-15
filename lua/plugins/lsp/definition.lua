-- Definition: go to definition of the symbol under cursor.
--
-- Behavior:
--   - No definition found: show notification message
--   - Single definition: jump directly without opening peekview
--   - Multiple definitions: open peekview with list + preview
--
-- Configuration (via vim.g globals, set before this file loads):
--   vim.g.definition_mode   - display mode "float" or "split" (default "float")
--   vim.g.definition_layout - layout config table, see PeekViewLayout in peekview.lua
--   vim.g.definition_keys   - keybinding config table { jump = "<CR>", close = "q" }

-- Load the generic location browser
local peekview = require("plugins.lsp.peekview")
-- Load the shared jump utility
local goto_loc = require("plugins.lsp.goto")

-- Entry point: invoke LSP definition and display results
local function open_definition()
  -- Record the window where user invoked the command (jump target)
  local source_win = vim.api.nvim_get_current_win()
  -- Capture the word under cursor for precise keyword highlighting in preview
  local word = vim.fn.expand("<cword>")

  local lsp = require("plugins.lsp.lsp")
  -- Call LSP textDocument/definition
  -- on_list callback runs in synchronous UI context (no flicker)
  lsp.definition({
    on_list = function(options)
      -- options.items: result from vim.lsp.util.locations_to_items()
      local items = options.items
      -- No definition found
      if #items == 0 then
        vim.notify("No definition found", vim.log.levels.INFO)
        return
      end

      -- Single definition: jump directly, no peekview needed
      if #items == 1 then
        goto_loc.jump_to(source_win, items[1])
        return
      end

      -- Multiple definitions: open peekview browser
      peekview.open({
        items = items,
        title = "Definitions (" .. #items .. ")",
        -- Pass word so preview highlights the exact keyword, not entire line
        word = word,
        -- Explicit source window (captured before async boundary)
        source_win = source_win,
        -- Read user config from globals (allows runtime modification)
        mode = vim.g.definition_mode or "float",
        layout = vim.g.definition_layout,
        keys = vim.g.definition_keys,
        -- Use Definition-specific highlight groups (defined in highlights.lua)
        highlights = {
          float = "DefinitionFloat",
          select = "DefinitionSelect",
          preview = "DefinitionPreview",
        },
      })
    end,
  })
end

return { open = open_definition }
