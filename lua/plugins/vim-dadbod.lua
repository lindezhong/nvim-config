-- Database client (tpope/vim-dadbod + kristijanhusak/vim-dadbod-ui)
--
-- SQL client inside Neovim supporting MySQL, PostgreSQL, SQLite, Redis, MongoDB etc.
--
-- Usage:
--   :DBUI                  open database client sidebar
--   :DBUIAddConnection     add a new database connection
--   :DBUIClose             close the sidebar
--
-- Data directory: ~/.local/share/db_ui (connections and saved queries)
--
-- Connection URL formats (passed to :DBUIAddConnection):
--   General:    adapter://[user[:password]@][host][:port]/[database]
--   MySQL:      mysql://user:pass@host:port/dbname
--   PostgreSQL: postgres://user:pass@host:port/dbname
--   SQLite:     sqlite:///path/to/file.db
--   Redis:      redis://user:pass@host:port
--   MongoDB:    mongodb://user:pass@host:port/dbname
--   Shell:      shell:///path/to/dir    (uses sh)
--               bash:///path/to/dir     (uses bash)
--               zsh:///path/to/dir      (uses zsh)
--               cmd:///C:/path/to/dir   (uses cmd.exe, Windows)
--               powershell:///path      (uses powershell, Windows)
--               pwsh:///path            (uses pwsh, cross-platform)
--               e.g. shell:///~/projects
--               Path must be absolute; ~ is expanded to $HOME (Unix only)
--               Omit path (e.g. shell://) to use Neovim's cwd
--               shell:/// uses / as working directory
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
-- Buffer binding (:DBBind):
--   Bind any file buffer to a DBUI connection so <Leader>e executes it.
--   Uses DBUI's native setup_buffer() internally, so the buffer gets the same
--   <Plug>(DBUI_ExecuteQuery) mappings as a DBUI query buffer.
--   Selection logic:
--     - 1 connected DB      → auto-bind (no prompt)
--     - N connected DBs     → pick from connected only
--     - 0 connected, 1 saved  → auto-bind from saved
--     - 0 connected, N saved  → pick from all saved connections
--   Example workflow:
--     1. Open a .sh or .sql file
--     2. :DBBind          (select or auto-bind a connection)
--     3. <Leader>e        (execute the file against the bound connection)
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
    cmd = { "DBUI", "DBUIToggle", "DBUIAddConnection", "DBUIFindBuffer", "DBBind" },
    init = function()
      -- All vim.g settings must be set BEFORE the plugin loads

      -- Register shell adapters for executing commands via DBUI
      -- Unix: shell→sh, bash→bash, zsh→zsh
      vim.g.db_adapter_shell = "DbShell_"
      vim.g.db_adapter_bash = "DbShell_"
      vim.g.db_adapter_zsh = "DbShell_"
      -- Windows: cmd→cmd.exe, powershell→powershell, pwsh→pwsh
      vim.g.db_adapter_cmd = "DbCmd_"
      vim.g.db_adapter_powershell = "DbPwsh_"
      vim.g.db_adapter_pwsh = "DbPwsh_"
      vim.cmd([[
        " --- shared: resolve working directory from URL ---
        function! s:resolve_dir(url) abort
          " scheme:// and scheme:/// both parse to path="/",
          " use raw URL to distinguish: no trailing path → Neovim cwd
          if a:url =~# '^[^:]\+://\%([?#]\|$\)'
            return getcwd()
          endif
          let dir = db#url#file_path(a:url)
          return substitute(dir, '^\~', $HOME, '')
        endfunction

        " --- Unix shells (sh/bash/zsh) ---
        function! DbShell_canonicalize(url) abort
          return substitute(a:url, '^\([^:]\+:///\)\~', '\1' . $HOME, '')
        endfunction
        function! DbShell_input_extension(...) abort
          return 'sh'
        endfunction
        function! DbShell_input(url, in) abort
          let scheme = get(db#url#parse(a:url), 'scheme', 'shell')
          let sh = scheme ==# 'shell' ? 'sh' : scheme
          let dir = s:resolve_dir(a:url)
          return [sh, '-c', 'cd ' . shellescape(dir) . ' && ' . shellescape(sh) . ' ' . shellescape(a:in)]
        endfunction
        function! DbShell_auth_input() abort
          return v:false
        endfunction

        " --- Windows cmd.exe ---
        function! DbCmd_input_extension(...) abort
          return 'bat'
        endfunction
        function! DbCmd_input(url, in) abort
          let dir = s:resolve_dir(a:url)
          return ['cmd', '/c', 'cd /d ' . shellescape(dir) . ' && cmd /c ' . shellescape(a:in)]
        endfunction
        function! DbCmd_auth_input() abort
          return v:false
        endfunction

        " --- PowerShell (powershell/pwsh) ---
        function! DbPwsh_input_extension(...) abort
          return 'ps1'
        endfunction
        function! DbPwsh_input(url, in) abort
          let scheme = get(db#url#parse(a:url), 'scheme', 'pwsh')
          let sh = scheme ==# 'powershell' ? 'powershell' : 'pwsh'
          let dir = s:resolve_dir(a:url)
          return [sh, '-NoProfile', '-Command',
                \ 'Set-Location ' . shellescape(dir) . '; & ' . shellescape(a:in)]
        endfunction
        function! DbPwsh_auth_input() abort
          return v:false
        endfunction
      ]])

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

      --- Bind current buffer to a DBUI connection.
      --- Establishes the connection via db_ui#get_conn_info (which triggers
      --- connect() internally), then registers the buffer through DBUIFindBuffer
      --- so it gets the standard DBUI buffer-local <Plug> mappings.
      --- @param conn {name: string, url: string, source: string, is_connected: integer}
      local function db_bind(conn)
        -- key_name format matches DBUI internals: "{name}_{source}"
        local key = conn.name .. "_" .. conn.source
        -- Ensure connection is established before DBUIFindBuffer;
        -- otherwise setup_buffer() would set b:db to empty string
        local ok, info = pcall(vim.fn["db_ui#get_conn_info"], key)
        if not ok or not info or (info.conn or "") == "" then
          vim.notify("Failed to connect: " .. conn.name, vim.log.levels.ERROR)
          return
        end
        vim.b.dbui_db_key_name = key
        vim.b.db = info.conn
        -- Registers buffer with DBUI and creates buffer-local <Plug> mappings
        vim.cmd("DBUIFindBuffer")
      end

      --- :DBBind — pick a DBUI connection and bind it to the current buffer.
      --- Prefers already-connected databases; falls back to all saved connections.
      --- Note: is_connected is a VimScript 0/1 number; Lua treats 0 as truthy,
      --- so we compare with == 1 explicitly.
      vim.api.nvim_create_user_command("DBBind", function()
        --- @type {name: string, url: string, source: string, is_connected: integer}[]
        local conns = vim.fn["db_ui#connections_list"]()
        -- Filter to already-connected databases
        local connected = vim.tbl_filter(function(c) return c.is_connected == 1 end, conns)
        -- Prefer connected; fall back to all saved connections
        local candidates = #connected > 0 and connected or conns
        if #candidates == 0 then
          vim.notify("No DBUI connections found", vim.log.levels.WARN)
          return
        end
        -- Single candidate: auto-bind without prompting
        if #candidates == 1 then
          db_bind(candidates[1])
          return
        end
        -- Multiple candidates: show picker (integrates with telescope if available)
        vim.ui.select(candidates, {
          prompt = "Select connection:",
          format_item = function(c)
            return c.name .. "  " .. c.url
          end,
        }, function(choice)
          if not choice then return end
          db_bind(choice)
        end)
      end, { desc = "Bind buffer to DBUI connection" })

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
