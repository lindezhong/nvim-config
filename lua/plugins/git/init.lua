-- Git plugin initialization module.
-- This file serves as the entry point for the entire git plugin. It:
--   1. Defines highlight groups for git status indicators across all views
--   2. Registers the :Git user command with subcommand completion
--   3. Sets up default normal-mode keymaps for common git operations
-- This file returns a lazy.nvim-compatible plugin spec table.
--
-- Commands:
--   :Git status [--unified]                     - show working tree status
--   :Git diff [ref1] [ref2] [--cached]          - show changes between refs
--                [--unified] [--current-file]
--   :Git log [--current-file] [-n N]            - browse commit history
--                [--author=name]
--   :Git blame [--date=relative|short] [-w]     - toggle inline blame annotations
--
-- Global keymaps:
--   <leader>gs    - :Git status
--   <leader>gd    - :Git diff
--   <leader>gl    - :Git log
--   <leader>gb    - :Git blame
--
-- Status/Diff view (file tree panel):
--   <CR>          - on file: open diff and focus diff pane
--                   on directory: toggle expand/collapse
--   q             - close the diff window
--   u             - toggle between vimdiff (side-by-side) and unified mode
--   R             - refresh file list from git
--   (cursor move) - preview diff for file under cursor (debounced)
--
-- Diff view (vimdiff panes, working tree mode):
--   do            - (diffget) revert hunk at cursor from old side
--   dp            - (diffput) push hunk at cursor to new side
--   ]c            - jump to next change
--   [c            - jump to previous change
--   The new (right) pane is the real file buffer; edits and :w are supported.
--   Known issue: closing with unsaved edits triggers E37; save first.
--
-- Log view (commit list panel):
--   <CR>          - open diff view for the selected commit
--   q             - close the log window
--   (cursor move) - show commit details in right pane (debounced)
--
-- Blame view (left panel synced with source):
--   <CR>          - open diff view for the commit on current line
--                   (works in both blame panel and source buffer)
--   q             - close blame panel
--   (scrollbind)  - blame panel scrolls with source buffer

--- Define highlight groups used by the git plugin UI.
-- Sets colors for modified, added, deleted, renamed, untracked files,
-- and for commit hashes displayed in the log view.
-- Called on startup and whenever the colorscheme changes to ensure
-- highlights persist across theme switches.
---@return nil
local function set_highlights()
  -- Yellow highlight for modified files (ctermfg=3 for terminal, fg for GUI)
  vim.api.nvim_set_hl(0, "GitModified", { ctermfg = 3, fg = "yellow" })
  -- Green highlight for added files (ctermfg=2 for terminal, fg for GUI)
  vim.api.nvim_set_hl(0, "GitAdded", { ctermfg = 2, fg = "green" })
  -- Red highlight for deleted files (ctermfg=1 for terminal, fg for GUI)
  vim.api.nvim_set_hl(0, "GitDeleted", { ctermfg = 1, fg = "red" })
  -- Blue highlight for renamed files (ctermfg=4 for terminal, fg for GUI)
  vim.api.nvim_set_hl(0, "GitRenamed", { ctermfg = 4, fg = "blue" })
  -- Green highlight for untracked (new) files (ctermfg=2 for terminal, fg for GUI)
  vim.api.nvim_set_hl(0, "GitUntracked", { ctermfg = 2, fg = "green" })
  -- Dark yellow highlight for commit hashes in the log view (ctermfg=3 for terminal)
  vim.api.nvim_set_hl(0, "GitLogHash", { ctermfg = 3, fg = "darkyellow" })
end

--- Main setup function for the git plugin.
-- Initializes highlights, registers the :Git user command,
-- and creates default normal-mode keymaps for git operations.
-- This function is called by lazy.nvim as the `config` callback
-- when the plugin is loaded.
---@return nil
local function setup()
  -- Apply highlight groups immediately on load
  set_highlights()
  -- Re-apply highlights whenever the user changes colorscheme,
  -- ensuring custom groups survive theme switches
  vim.api.nvim_create_autocmd("ColorScheme", { callback = set_highlights })

  -- Load the command dispatcher module that handles :Git subcommands
  ---@type table The command module with execute() and complete() functions
  local cmd = require("plugins.git.command")
  -- Register the :Git user command that delegates to subcommand handlers.
  -- nargs="+" requires at least one argument (the subcommand name).
  -- complete=cmd.complete provides tab-completion for subcommands and flags.
  vim.api.nvim_create_user_command("Git", function(opts)
    -- Dispatch the raw argument string to the command module for parsing and execution
    cmd.execute(opts.args)
  end, { nargs = "+", complete = cmd.complete })

  -- Set up default keymaps for quick access to git operations.
  -- All keymaps are in normal mode under the <leader>g prefix.
  -- <leader>gs opens the git status view showing modified/added/deleted files
  vim.keymap.set("n", "<leader>gs", "<cmd>Git status<CR>", { silent = true })
  -- <leader>gd opens the git diff view showing unstaged changes
  vim.keymap.set("n", "<leader>gd", "<cmd>Git diff<CR>", { silent = true })
  -- <leader>gl opens the git log viewer to browse commit history
  vim.keymap.set("n", "<leader>gl", "<cmd>Git log<CR>", { silent = true })
  -- <leader>gb toggles inline git blame annotations on the current buffer
  vim.keymap.set("n", "<leader>gb", "<cmd>Git blame<CR>", { silent = true })
end

-- Return a lazy.nvim plugin spec table.
-- Uses dir="." to indicate this is a local plugin (loaded from the config
-- directory itself, not fetched from a remote git repository).
-- The `config` field points to the setup() function which runs on load.
---@type LazyPluginSpec[]
return {
  { dir = ".", name = "git-local", config = setup },
}
