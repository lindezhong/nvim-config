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
-- Color scheme with custom dark background overrides (see colors/vim8.vim)
vim.cmd.colorscheme("vim8")

-- Load all plugin configs from lua/plugins/
require("lazy").setup("plugins")
