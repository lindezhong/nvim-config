-- Custom LSP interaction handlers
--
-- Functions used by keymaps that need logic beyond a single vim.lsp.buf call:
-- scroll_float, references (floating picker), document_outline (right panel)

local M = {}

-- Scroll float window (hover/signature popup) without focusing it
function M.scroll_float(direction)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      local scroll_cmd = direction > 0 and "\\<C-e>" or "\\<C-y>"
      vim.api.nvim_win_call(win, function()
        vim.cmd("normal! " .. math.abs(direction) .. scroll_cmd)
      end)
      return true
    end
  end
  return false
end

-- Show document symbols in a right-side location list panel
function M.document_outline()
  vim.lsp.buf.document_symbol({
    on_list = function(options)
      vim.fn.setloclist(0, {}, " ", options)
      vim.cmd("vert botright lopen 40")
    end,
  })
end

return M
