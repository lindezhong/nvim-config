-- File tree sidebar (nvim-tree/nvim-tree.lua)
--
-- Sidebar file explorer with directory tree view:
-- 1. Toggle: Esc+C-n to open/close the tree panel
-- 2. Locate: Esc+S-n to reveal current file in the tree
-- 3. Filters: hide .git, .idea, .vscode, .vim, .github, .swp etc.
-- 4. Auto-close: quit nvim when tree is the last window
-- 5. Terminal integration: auto-close tree on :Terminal
--
-- Built-in keybindings inside the tree panel:
--   o / <CR>  open file or toggle directory
--   a         create a new file or directory (append / to name for directory)
--   d         delete file or directory
--   r         rename file or directory
--   x         collapse parent directory
--   H         toggle hidden (dotfiles) visibility
--   i         open in horizontal split
--   s         open in vertical split
--   R         refresh the tree
--   f         live filter (type to search, only matching files shown)
--   F         clear live filter
--   c         mark file for copy
--   x         mark file for cut (move)
--   p         paste (copy/move marked file to current directory)
--   y         copy filename to clipboard
--   Y         copy relative path to clipboard
--   gy        copy absolute path to clipboard
--   g?        toggle help (show all keybindings)

return {
  {
    "nvim-tree/nvim-tree.lua",
    config = function()
      -- Disable neovim's built-in file explorer to avoid conflicts
      vim.g.loaded_netrw = 1
      vim.g.loaded_netrwPlugin = 1

      require("nvim-tree").setup({
        -- Tree panel position and width
        view = { side = "left", width = 30 },
        renderer = {
          icons = {
            -- Disable file/folder/git icons (no nerd font), keep only folder arrows
            show = { file = false, folder = false, folder_arrow = true, git = false },
            glyphs = {
              -- ASCII-friendly arrow characters for collapsed/expanded directories
              folder = { arrow_closed = "▸", arrow_open = "▾" },
              -- Git status characters (requires git.enable = true and show.git = true)
              git = {
                unstaged = "M", staged = "S", unmerged = "U",
                renamed = "R", untracked = "?", deleted = "D", ignored = "!",
              },
            },
          },
        },
        diagnostics = {
          -- Show LSP diagnostic signs (E/W/H/I) next to files with issues
          enable = true,
          -- Propagate diagnostic status to parent directories
          show_on_dirs = true,
          -- Use letters instead of icons for terminal compatibility
          icons = { error = "E", warning = "W", hint = "H", info = "I" },
        },
        git = {
          -- Git status marks next to files (M=modified, U=untracked, S=staged etc.)
          enable = false,
        },
        filesystem_watchers = {
          -- Auto-refresh tree when files change on disk (uses inotify/FSEvents/ReadDirectoryChangesW)
          enable = true,
        },
        filters = {
          -- Show dotfiles (hidden files starting with .)
          dotfiles = false,
          -- Hide these specific patterns from the tree
          custom = { "^\\.git$", "^\\.idea$", "^\\.vscode$", "^\\.vim$", "^\\.github$", "^\\.gitignore$", "^\\.vimspector\\.json$", "\\.swp$" },
        },
        actions = {
          -- Keep tree open after opening a file (don't auto-close)
          open_file = { quit_on_open = false },
        },
      })

      -- Hide statusline text in the tree window
      vim.api.nvim_create_autocmd("BufWinEnter", {
        callback = function()
          if vim.bo.filetype == "NvimTree" then
            vim.wo.statusline = " "
          end
        end,
      })

      -- Toggle tree panel
      vim.keymap.set("n", "<Esc><C-n>", "<cmd>NvimTreeToggle<CR>", { silent = true })
      vim.keymap.set("i", "<Esc><C-n>", "<Esc>`^<cmd>NvimTreeToggle<CR>", { silent = true })
      -- Reveal current file in the tree
      vim.keymap.set("n", "<Esc><S-n>", "<cmd>NvimTreeFindFile<CR>", { silent = true })
      vim.keymap.set("i", "<Esc><S-n>", "<Esc>`^<cmd>NvimTreeFindFile<CR>", { silent = true })

      -- Auto-close nvim when tree is the last remaining window
      vim.api.nvim_create_autocmd("BufEnter", {
        nested = true,
        callback = function()
          local wins = vim.api.nvim_list_wins()
          if #wins == 1 and require("nvim-tree.utils").is_nvim_tree_buf() then
            vim.cmd("quit")
          end
        end,
      })

      -- Close tree when entering fullscreen :Terminal
      require("commands").register_terminal("nvim-tree", function()
        require("nvim-tree.api").tree.close()
      end)
    end,
  },
}
