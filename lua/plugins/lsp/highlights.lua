-- LSP highlight groups
--
-- Defines highlight groups used by LSP UI components.

local M = {}

function M.setup()
  -- PeekView defaults (used when caller doesn't specify highlights)
  vim.api.nvim_set_hl(0, "PeekViewFloat", { ctermbg = "Black", ctermfg = "White" })
  vim.api.nvim_set_hl(0, "PeekViewSelect", { ctermfg = "Black", ctermbg = "Cyan" })
  vim.api.nvim_set_hl(0, "PeekViewPreview", { link = "PeekViewSelect" })
  -- References (links to PeekView defaults, override for custom colors)
  vim.api.nvim_set_hl(0, "ReferencesFloat", { link = "PeekViewFloat" })
  vim.api.nvim_set_hl(0, "ReferencesSelect", { link = "PeekViewSelect" })
  vim.api.nvim_set_hl(0, "ReferencesPreview", { link = "PeekViewPreview" })
  -- Definition (links to PeekView defaults, override for custom colors)
  vim.api.nvim_set_hl(0, "DefinitionFloat", { link = "PeekViewFloat" })
  vim.api.nvim_set_hl(0, "DefinitionSelect", { link = "PeekViewSelect" })
  vim.api.nvim_set_hl(0, "DefinitionPreview", { link = "PeekViewPreview" })
end

return M
