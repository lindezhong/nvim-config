-- Neovim entry point configuration
--
-- This file sets up the editor environment:
-- 1. Plugin manager: lazy.nvim (auto-install and bootstrap)
-- 2. Editor options: line numbers, sign column, dark background
-- 3. Diagnostics: display style for errors/warnings (signs only, no virtual text)
-- 4. Colors: terminal color scheme and highlight overrides
-- Bootstrap lazy.nvim plugin manager (auto-clone on first launch)

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- Show line numbers
vim.opt.number = true
-- Merge sign column into line number column to save horizontal space
vim.opt.signcolumn = "number"

-- Diagnostic display: signs only (no inline virtual text after code lines)
-- Signs use letters (E/W/I/H) instead of icons for terminal compatibility
vim.diagnostic.config({
  virtual_text = false,
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = "E",
      [vim.diagnostic.severity.WARN] = "W",
      [vim.diagnostic.severity.INFO] = "I",
      [vim.diagnostic.severity.HINT] = "H",
    },
  },
})

-- Disable true color (use 256-color terminal palette instead)
vim.opt.termguicolors = false
vim.cmd.colorscheme("vim8")

-- Highlight overrides for dark terminal background
-- Usage: vim.api.nvim_set_hl(0, "Group", { ctermfg = "Color", ctermbg = "Color", cterm = { bold = true } })
-- Available colors: Black, Red, Green, Yellow, Blue, Magenta, Cyan, White,
--   DarkGray, LightGray, LightRed, LightGreen, LightBlue, LightMagenta, LightCyan (or 0-255)
-- Available attrs: bold, underline, reverse, italic, strikethrough
-- Editor background
vim.api.nvim_set_hl(0, "Normal", { ctermbg = "Black" })
-- Visual selection highlight
vim.api.nvim_set_hl(0, "Visual", { ctermfg = "Black" })
-- Diff colors for vimdiff / git diff view
vim.api.nvim_set_hl(0, "DiffChange", { ctermfg = "Black", ctermbg = "Blue" })
vim.api.nvim_set_hl(0, "DiffText", { ctermfg = "Black", ctermbg = "Red" })
vim.api.nvim_set_hl(0, "DiffAdd", { ctermfg = "Black", ctermbg = "Blue" })
vim.api.nvim_set_hl(0, "DiffDelete", { ctermfg = "Black", ctermbg = "Blue" })
-- Window separator between splits
vim.api.nvim_set_hl(0, "WinSeparator", { cterm = { reverse = true } })
-- Diagnostic signs in the sign/number column
vim.api.nvim_set_hl(0, "DiagnosticSignError", { ctermfg = "Red", ctermbg = "Black" })
vim.api.nvim_set_hl(0, "DiagnosticSignWarn", { ctermfg = "Yellow", ctermbg = "Black" })
vim.api.nvim_set_hl(0, "DiagnosticSignInfo", { ctermfg = "Blue", ctermbg = "Black" })
vim.api.nvim_set_hl(0, "DiagnosticSignHint", { ctermfg = "Cyan", ctermbg = "Black" })
-- Sign column background (match Normal)
vim.api.nvim_set_hl(0, "SignColumn", { ctermbg = "Black" })

-- Load all plugin configs from lua/plugins/
require("lazy").setup("plugins")
