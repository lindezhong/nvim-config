-- LSP highlight groups
--
-- Defines highlight groups used by LSP UI components.

local M = {}

local function set_highlights()
  -- PeekView defaults (used when caller doesn't specify highlights)
  vim.api.nvim_set_hl(0, "PeekViewFloat", { ctermbg = "Black", ctermfg = "White" })
  vim.api.nvim_set_hl(0, "PeekViewSelect", { link = "PmenuSel" })
  vim.api.nvim_set_hl(0, "PeekViewPreview", { link = "Search" })
  -- References (links to PeekView defaults, override for custom colors)
  vim.api.nvim_set_hl(0, "ReferencesFloat", { link = "PeekViewFloat" })
  vim.api.nvim_set_hl(0, "ReferencesSelect", { link = "PeekViewSelect" })
  vim.api.nvim_set_hl(0, "ReferencesPreview", { link = "PeekViewPreview" })
  -- Definition (links to PeekView defaults, override for custom colors)
  vim.api.nvim_set_hl(0, "DefinitionFloat", { link = "PeekViewFloat" })
  vim.api.nvim_set_hl(0, "DefinitionSelect", { link = "PeekViewSelect" })
  vim.api.nvim_set_hl(0, "DefinitionPreview", { link = "PeekViewPreview" })
end

function M.setup()
  set_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = set_highlights })
end

return M
