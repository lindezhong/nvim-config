-- Global keybindings (non-plugin, non-LSP)
--
-- LSP keybindings are in lua/plugins/lsp.lua (buffer-local, on LspAttach)
-- Completion keybindings are in lua/plugins/cmp.lua

-- Buffer navigation: switch between open files
vim.keymap.set("n", "<C-Right>", "<cmd>bn<CR>", { silent = true })
vim.keymap.set("n", "<C-Left>", "<cmd>bp<CR>", { silent = true })
vim.keymap.set("i", "<C-Right>", "<Esc>`^<cmd>bn<CR>i", { silent = true })
vim.keymap.set("i", "<C-Left>", "<Esc>`^<cmd>bp<CR>i", { silent = true })
vim.keymap.set("n", "<C-l>", "<cmd>bn<CR>", { silent = true })
vim.keymap.set("n", "<C-h>", "<cmd>bp<CR>", { silent = true })
vim.keymap.set("i", "<C-l>", "<Esc>`^<cmd>bn<CR>i", { silent = true })
vim.keymap.set("i", "<C-h>", "<Esc>`^<cmd>bp<CR>i", { silent = true })
-- Close current buffer
vim.keymap.set("n", "<C-n>", "<cmd>bd<CR>", { silent = true })
vim.keymap.set("i", "<C-n>", "<Esc>`^<cmd>bd<CR>i", { silent = true })

-- Terminal mode: exit with Esc (nvim uses <C-\><C-n> instead of vim's <C-w>N)
vim.keymap.set("t", "<Esc>", "<C-\\><C-n>")

-- Window navigation via Ctrl+Alt+hjkl
vim.keymap.set("n", "<C-A-h>", "<C-w><C-h>", { silent = true })
vim.keymap.set("n", "<C-A-l>", "<C-w><C-l>", { silent = true })
vim.keymap.set("n", "<C-A-k>", "<C-w><C-k>", { silent = true })
vim.keymap.set("n", "<C-A-j>", "<C-w><C-j>", { silent = true })
vim.keymap.set("i", "<C-A-h>", "<Esc>`^<C-w><C-h>", { silent = true })
vim.keymap.set("i", "<C-A-l>", "<Esc>`^<C-w><C-l>", { silent = true })
vim.keymap.set("i", "<C-A-k>", "<Esc>`^<C-w><C-k>", { silent = true })
vim.keymap.set("i", "<C-A-j>", "<Esc>`^<C-w><C-j>", { silent = true })
-- Window navigation via Ctrl+Alt+arrows
vim.keymap.set("n", "<C-A-Left>", "<C-w><C-h>", { silent = true })
vim.keymap.set("n", "<C-A-Right>", "<C-w><C-l>", { silent = true })
vim.keymap.set("n", "<C-A-Up>", "<C-w><C-k>", { silent = true })
vim.keymap.set("n", "<C-A-Down>", "<C-w><C-j>", { silent = true })
vim.keymap.set("i", "<C-A-Left>", "<Esc>`^<C-w><C-h>", { silent = true })
vim.keymap.set("i", "<C-A-Right>", "<Esc>`^<C-w><C-l>", { silent = true })
vim.keymap.set("i", "<C-A-Up>", "<Esc>`^<C-w><C-k>", { silent = true })
vim.keymap.set("i", "<C-A-Down>", "<Esc>`^<C-w><C-j>", { silent = true })

-- Save file
vim.keymap.set("n", "<C-S>", "<cmd>w!<CR>i")
vim.keymap.set("v", "<C-S>", "<C-c><cmd>w!<CR>")
vim.keymap.set("i", "<C-S>", "<Esc><cmd>w!<CR>i")

-- Jump back/forward in jumplist
vim.keymap.set("n", "<A-Left>", "<C-o>")
vim.keymap.set("n", "<A-Right>", "<C-i>")
vim.keymap.set("i", "<A-Left>", "<Esc>`^<C-o>")
vim.keymap.set("i", "<A-Right>", "<Esc>`^<C-i>")
vim.keymap.set("n", "<A-h>", "<C-o>")
vim.keymap.set("n", "<A-l>", "<C-i>")
vim.keymap.set("i", "<A-h>", "<Esc>`^<C-o>")
vim.keymap.set("i", "<A-l>", "<Esc>`^<C-i>")

-- Keep cursor position when leaving insert mode (prevent moving 1 char left)
vim.keymap.set("i", "<Esc>", "<Esc>`^")

-- Close any floating window on Esc (LSP hover, diagnostics, dict, etc.)
vim.keymap.set("n", "<Esc>", function()
  local closed = false
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
      vim.api.nvim_win_close(win, true)
      closed = true
    end
  end
  if not closed then
    vim.cmd("nohlsearch")
  end
end)

-- Redo (since C-r is remapped to search-replace below)
vim.keymap.set("n", "<S-u>", "<cmd>redo<CR>", { silent = true })

-- Page scroll with Shift+j/k
vim.keymap.set("n", "<S-j>", "<C-f>")
vim.keymap.set("n", "<S-k>", "<C-b>")
vim.keymap.set("v", "<S-j>", "<C-f>")
vim.keymap.set("v", "<S-k>", "<C-b>")

-- Word jump with Shift+h/l
vim.keymap.set("n", "<S-h>", "<S-Left>")
vim.keymap.set("n", "<S-l>", "<S-Right>")
vim.keymap.set("v", "<S-h>", "<S-Left>")
vim.keymap.set("v", "<S-l>", "<S-Right>")

-- Window resize
vim.keymap.set("n", "<C-PageUp>", "<cmd>vertical res+1<CR>", { silent = true })
vim.keymap.set("n", "<C-PageDown>", "<cmd>vertical res-1<CR>", { silent = true })
vim.keymap.set("n", "<A-PageUp>", "<cmd>res+1<CR>", { silent = true })
vim.keymap.set("n", "<A-PageDown>", "<cmd>res-1<CR>", { silent = true })

-- Copy selection to system clipboard
vim.keymap.set("v", "<C-y>", '"+y')

-- Search-replace (overrides default C-r redo, use S-u for redo instead)
vim.keymap.set("n", "<C-r>", ":%s///g")
vim.keymap.set("i", "<C-r>", "<Esc>:%s///g")
