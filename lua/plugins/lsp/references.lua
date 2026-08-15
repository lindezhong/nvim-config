-- References: find all references of the symbol under cursor.
--
-- Behavior:
--   - No references found: show notification message
--   - Single reference: jump directly without opening peekview
--   - Multiple references: open peekview with list + preview
--
-- Configuration (via vim.g globals, set before this file loads):
--   vim.g.references_mode   - display mode "float" or "split" (default "float")
--   vim.g.references_layout - layout config table, see PeekViewLayout in peekview.lua
--   vim.g.references_keys   - keybinding config table { jump = "<CR>", close = "q" }

-- Load the generic location browser
local peekview = require("plugins.lsp.peekview")
-- Load the shared jump utility
local goto_loc = require("plugins.lsp.goto")

-- Entry point: invoke LSP references and display results
local function open_references()
  -- Record the window where user invoked the command (jump target)
  local source_win = vim.api.nvim_get_current_win()
  -- Capture the word under cursor for precise keyword highlighting in preview
  local word = vim.fn.expand("<cword>")

  -- Call LSP textDocument/references
  -- on_list callback runs in synchronous UI context (no flicker)
  vim.lsp.buf.references(nil, {
    on_list = function(options)
      -- options.items: result from vim.lsp.util.locations_to_items()
      local items = options.items
      -- No references found
      if #items == 0 then
        vim.notify("No references found", vim.log.levels.INFO)
        return
      end

      -- Single reference: jump directly, no peekview needed
      if #items == 1 then
        goto_loc.jump_to(source_win, items[1])
        return
      end

      -- Multiple references: open peekview browser
      peekview.open({
        items = items,
        title = "References (" .. #items .. ")",
        -- Pass word so preview highlights the exact keyword, not entire line
        word = word,
        -- Explicit source window (captured before async boundary)
        source_win = source_win,
        -- Read user config from globals (allows runtime modification)
        mode = vim.g.references_mode or "float",
        layout = vim.g.references_layout,
        keys = vim.g.references_keys,
        -- Use References-specific highlight groups (defined in highlights.lua)
        highlights = {
          float = "ReferencesFloat",
          select = "ReferencesSelect",
          preview = "ReferencesPreview",
        },
      })
    end,
  })
end

return { open = open_references }
