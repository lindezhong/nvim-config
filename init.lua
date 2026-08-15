-- Neovim entry point configuration
--
-- This file sets up the editor environment:
-- 1. Plugin manager: lazy.nvim (auto-install and bootstrap)
-- 2. Editor options: indentation, display, behavior
-- 3. FileType: per-language indentation rules
-- 4. Diagnostics: display style for errors/warnings
-- 5. Colors: terminal color scheme
-- 6. Modules: keymaps, session, commands, plugins

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


-- ===== Editor options =====

-- Show line numbers
vim.opt.number = true
-- Merge sign column into line number column to save horizontal space
vim.opt.signcolumn = "number"
-- Indentation: 4 spaces, expand tabs
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
-- C-style auto indentation for braces/blocks
vim.opt.cindent = true
-- Do not wrap long lines (use :set wrap to restore)
vim.opt.wrap = false
-- Hide right-bottom cursor position display
vim.opt.ruler = false
-- Faster CursorHold events (default 4000ms is too slow for LSP)
vim.opt.updatetime = 300
-- Don't show completion messages in cmdline (e.g. "match 1 of 2")
vim.opt.shortmess:append("c")
-- Don't create backup file before overwriting
vim.opt.writebackup = false
-- Block cursor in all modes (nvim defaults to beam in insert mode)
vim.opt.guicursor = "n-v-c-i:block"
-- Only show statusline when multiple windows are open
vim.opt.laststatus = 1
-- Fill characters for separators and folds
vim.opt.fillchars:append({ vert = "|", fold = "-", eob = "~" })
-- Border style for all floating windows (hover, completion docs, diagnostics, etc.)
-- "none"    - no border
-- "single"  - thin single line  ┌─┐│└─┘│
-- "double"  - double line       ╔═╗║╚═╝║
-- "rounded" - single with round corners ╭─╮│╰─╯│
-- "solid"   - filled block characters (thick border)
-- "shadow"  - shadow effect on bottom-right edges
-- Or a table of 8 chars: {topleft, top, topright, right, botright, bot, botleft, left}
vim.o.winborder = "rounded"

-- ===== FileType indentation =====

-- Languages that use 2-space indentation
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "sql", "mysql", "yaml", "html", "css", "javascript", "javascriptreact", "typescript" },
  callback = function()
    vim.opt_local.tabstop = 2
    vim.opt_local.shiftwidth = 2
  end,
})

-- ===== Diagnostics =====

-- Signs only (no inline virtual text after code lines)
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

-- ===== Colors =====

-- Disable true color (use 256-color terminal palette instead)
vim.opt.termguicolors = false
-- Color scheme with custom dark background overrides (see colors/vim8.vim)
vim.cmd.colorscheme("vim8-dark")

-- ===== Modules =====

-- Global keybindings: buffer/window navigation, save, jumplist, scroll, etc.
require("keymaps")
-- Directory-level session auto save/load with plugin hook interface
require("session")
-- Custom commands: :Exit, :Q, :Terminal with plugin hook interface
require("commands")
-- Plugin configs from lua/plugins/ (LSP, completion, treesitter, etc.)
require("lazy").setup("plugins")
