-- Database client (tpope/vim-dadbod + kristijanhusak/vim-dadbod-ui)
--
-- SQL client inside Neovim supporting MySQL, PostgreSQL, SQLite, Redis, MongoDB etc.
--
-- Usage:
--   :DBUI                  open database client sidebar
--   :DBUIAddConnection     add a new database connection
--   :DBUIClose             close the sidebar
--
-- Connection URL formats (passed to :DBUIAddConnection):
--   General:    adapter://[user[:password]@][host][:port]/[database]
--   MySQL:      mysql://user:pass@host:port/dbname
--   PostgreSQL: postgres://user:pass@host:port/dbname
--   SQLite:     sqlite:///path/to/file.db
--   Redis:      redis://user:pass@host:port
--   MongoDB:    mongodb://user:pass@host:port/dbname
--   Full URL syntax: :h dadbod-adapters (need run :DBUI first to load help)
--
-- Sidebar keybindings (inside DBUI drawer):
--   o / <CR>  open/toggle item
--   S         open in vertical split
--   d         delete buffer or saved query
--   R         redraw
--   A         add connection
--   H         toggle database details
--
-- SQL buffer keybindings:
--   <Leader>w  save query to file
--   <Leader>e  execute SQL or re-edit bind params (normal) / execute selection (visual)
--   <Leader>r  toggle expanded result view (like MySQL \G)
--
-- Bind parameters:
--   Use `:variable` syntax in SQL to define bind parameters.
--   Example: select * from users where id = :id and status = :status;
--   Workflow:
--     1. First run: visual-select SQL → <Leader>e → prompts for each :param value
--     2. Edit params: normal <Leader>e → select param to edit/delete, then re-execute
--   Note: normal <Leader>e (EditBindParameters) only works AFTER the first
--   visual execution has established param values. This is a plugin limitation:
--   params are created during ExecuteQuery, not EditBindParameters.
--
-- Completion: nvim-cmp automatically provides table/column name completions
-- in sql/mysql/plsql buffers via vim-dadbod-completion source.

--- @type LazyPluginSpec[]
return {
  {
    "kristijanhusak/vim-dadbod-ui",
    dependencies = {
      { "tpope/vim-dadbod", lazy = true },
      { "kristijanhusak/vim-dadbod-completion", ft = { "sql", "mysql", "plsql" }, lazy = true },
    },
    cmd = { "DBUI", "DBUIToggle", "DBUIAddConnection", "DBUIFindBuffer" },
    init = function()
      -- All vim.g settings must be set BEFORE the plugin loads

      -- Don't auto-execute SQL on :w (default, explicit for clarity)
      vim.g.db_ui_execute_on_save = 0
      -- Sidebar drawer width (characters)
      vim.g.db_ui_winwidth = 30
      -- Notification popup width (keep smaller than drawer)
      vim.g.db_ui_notification_width = 25
      -- Auto-execute table helper queries when selected
      vim.g.db_ui_auto_execute_table_helpers = 1
      -- Suppress info-level notifications (only show warnings/errors)
      vim.g.db_ui_disable_info_notifications = 1

      -- Custom table helpers: quick queries available per table in the sidebar
      vim.g.db_ui_table_helpers = {
        mysql = {
          Columns = 'SELECT COLUMN_NAME AS "Field", COLUMN_TYPE AS "Type", COLUMN_COMMENT AS "Comment", IS_NULLABLE AS "NULL", COLUMN_DEFAULT AS "Default", COLUMN_KEY AS "Key", EXTRA AS "Extra" FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = "{table}";',
          Schema = "SHOW CREATE TABLE `{table}`;",
        },
      }
    end,
    config = function()
      -- <Plug> mappings require remap=true (vim.keymap.set defaults to noremap)
      local remap = { silent = true, remap = true }

      -- Save query to file
      vim.keymap.set("n", "<Leader>w", "<Plug>(DBUI_SaveQuery)", remap)
      -- Execute SQL / edit bind parameters (normal mode)
      vim.keymap.set("n", "<Leader>e", "<Plug>(DBUI_EditBindParameters)", remap)
      -- Execute selected SQL (visual mode)
      vim.keymap.set("v", "<Leader>e", "<Plug>(DBUI_ExecuteQuery)", remap)
      -- Toggle expanded result view (MySQL \G style)
      vim.keymap.set("n", "<Leader>r", "<Plug>(DBUI_ToggleResultLayout)", remap)

      -- nvim-cmp integration: add dadbod completion source for SQL filetypes
      vim.api.nvim_create_autocmd("FileType", {
        pattern = { "sql", "mysql", "plsql" },
        callback = function()
          local ok, cmp = pcall(require, "cmp")
          if not ok then return end
          cmp.setup.buffer({
            sources = cmp.config.sources({
              { name = "vim-dadbod-completion" },
              { name = "luasnip" },
            }, {
              { name = "buffer" },
            }),
          })
        end,
      })
    end,
  },
}
