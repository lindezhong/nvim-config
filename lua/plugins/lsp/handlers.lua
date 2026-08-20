-- Custom LSP interaction handlers
--
-- Functions used by keymaps that need logic beyond a single vim.lsp.buf call:
-- scroll_float, references (floating picker), document_outline (right panel)

local M = {}

-- Scroll float window (hover/signature popup) without focusing it
-- key: pre-converted terminal key code (e.g. from nvim_replace_termcodes)
function M.scroll_float(key)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      vim.api.nvim_win_call(win, function()
        vim.cmd("normal! " .. key)
      end)
      return true
    end
  end
  return false
end

-- Show document symbols in a right-side location list panel
function M.document_outline()
  local lsp = require("plugins.lsp.lsp")
  lsp.document_symbol({
    on_list = function(options)
      vim.fn.setloclist(0, {}, " ", options)
      vim.cmd("vert botright lopen 40")
    end,
  })
end

return M
