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
--   Shell SSH:  bash://user@host/remote/path
--               bash://user:pass@host:port/remote/path
--               zsh://admin@10.0.0.1/home/admin/scripts
--               pwsh://admin@winhost/tmp
--               cmd://admin@winhost/C:/scripts
--               cmd SSH limitation: lines joined with ' & ', multi-line
--               if/for/^ constructs in .bat files will break
--               Omit path → remote home directory
--               ~ in path expanded on remote (e.g. bash://user@host/~/proj)
--               Password in URL uses SSH_ASKPASS (no sshpass needed)
--               First-time host trust handled via StrictHostKeyChecking=accept-new
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
-- Working directory override (:DBCd):
--   Temporarily override the working directory for the current buffer.
--   Only affects shell adapters (shell, bash, zsh, cmd, powershell, pwsh).
--   :DBCd /tmp          set working directory to /tmp
--   :DBCd ~/projects    set to ~/projects (~ expanded locally or remotely)
--   :DBCd               reset to URL path (default behavior)
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
--     1. Open a .sql file
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
    cmd = { "DBUI", "DBUIToggle", "DBUIAddConnection", "DBUIFindBuffer", "DBBind", "DBCd" },
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
        " --- shared: path quoting and working directory ---

        " Quote a path for POSIX shell, keeping ~ outside quotes for expansion.
        " @param path string  filesystem path (may start with ~)
        " @return string  shell-safe quoted path
        function! s:sh_quote(path) abort
          if a:path ==# '~'
            return '~'
          endif
          if a:path =~# '^\~/'
            return '~/' . shellescape(a:path[2:])
          endif
          return shellescape(a:path)
        endfunction

        " Returns local working directory for the given adapter URL.
        " For no-path URLs (scheme://), falls back to Neovim's cwd.
        " @param url string  adapter URL
        " @return string  directory path (may contain ~)
        function! s:resolve_dir(url) abort
          if exists('b:db_cwd') && !empty(b:db_cwd)
            return b:db_cwd
          endif
          " scheme:// and scheme:/// both parse to path="/",
          " use raw URL to distinguish: no trailing path → Neovim cwd
          if a:url =~# '^[^:]\+://\%([?#]\|$\)'
            return getcwd()
          endif
          return db#url#file_path(a:url)
        endfunction

        " --- shared: SSH remote execution helpers ---

        " Check if URL targets a remote host (has host component).
        " @param parsed dict  result of db#url#parse()
        " @return boolean  1 if remote, 0 if local
        function! s:is_remote(parsed) abort
          return has_key(a:parsed, 'host') && !empty(a:parsed.host)
        endfunction

        " Build 'ssh [opts] user@host' prefix as a string.
        " Includes -o StrictHostKeyChecking=accept-new for first-time trust,
        " and ControlMaster/ControlPersist for connection reuse (avoids
        " repeated TCP handshake + key exchange on every query execution).
        " @param parsed dict  result of db#url#parse()
        " @return string  ssh command prefix (e.g. 'ssh -o ... -p 22 admin@host')
        function! s:ssh_prefix(parsed) abort
          let parts = ['ssh',
                \ '-o', 'StrictHostKeyChecking=accept-new',
                \ '-o', 'ConnectTimeout=5',
                \ '-o', 'ControlMaster=auto',
                \ '-o', 'ControlPath=/tmp/dbui-ssh-%r@%h:%p',
                \ '-o', 'ControlPersist=600']
          if has_key(a:parsed, 'port') && !empty(a:parsed.port)
            call extend(parts, ['-p', a:parsed.port])
          endif
          let target = (has_key(a:parsed, 'user') && !empty(a:parsed.user) ? a:parsed.user . '@' : '') . a:parsed.host
          call add(parts, target)
          return join(map(parts, 'shellescape(v:val)'), ' ')
        endfunction

        " Resolve remote working directory from b:db_cwd or URL path.
        " @param url string  raw adapter URL (used to distinguish no-path from '/')
        " @param parsed dict  result of db#url#parse()
        " @return string  resolved path (may contain ~), or '' for home dir
        function! s:resolve_remote_path(url, parsed) abort
          if exists('b:db_cwd') && !empty(b:db_cwd)
            let path = b:db_cwd
          else
            let path = get(a:parsed, 'path', '')
            if empty(path)
              return ''
            endif
            " No explicit path after authority (e.g. bash://user@host:22)
            " db#url#parse returns '/' for both this and bash://user@host:22/
            if path ==# '/' && a:url =~# '://[^/]*$'
              return ''
            endif
          endif
          " /~/foo → ~/foo (let remote shell expand ~)
          if path =~# '^/\~'
            let path = path[1:]
          endif
          return path
        endfunction

        " Build remote 'cd /path && ' prefix for Unix shells (sh/bash/zsh/pwsh).
        " Returns empty string when path is empty (use remote home dir).
        " Path '/' generates 'cd / && ' (root directory).
        " ~ is kept outside quotes so the remote shell expands it.
        " @param url string  raw adapter URL
        " @param parsed dict  result of db#url#parse()
        " @return string  'cd /path && ' or ''
        function! s:remote_cd(url, parsed) abort
          let path = s:resolve_remote_path(a:url, a:parsed)
          if empty(path)
            return ''
          endif
          return 'cd ' . s:sh_quote(path) . ' && '
        endfunction

        " Build remote 'cd /d "path" && ' prefix for cmd.exe.
        " Uses double quotes (cmd.exe does not recognize single quotes).
        " Warns if path contains ~ (cmd.exe cannot expand it).
        " @param url string  raw adapter URL
        " @param parsed dict  result of db#url#parse()
        " @return string  'cd /d "path" && ' or ''
        function! s:remote_cd_cmd(url, parsed) abort
          let path = s:resolve_remote_path(a:url, a:parsed)
          if empty(path)
            return ''
          endif
          if path =~# '\~'
            echohl WarningMsg | echomsg 'DBCd: cmd.exe does not support ~ in paths' | echohl None
          endif
          " /C:/scripts → C:/scripts (URL path has leading / before drive letter)
          if path =~# '^/[A-Za-z]:'
            let path = path[1:]
          endif
          return 'cd /d "' . substitute(path, '"', '', 'g') . '" && '
        endfunction

        " Wrap an SSH command with SSH_ASKPASS for password-based auth.
        " Creates a temp askpass script, runs the command, cleans up.
        " When no password is present, returns the command unchanged.
        " @param parsed dict  result of db#url#parse()
        " @param ssh_cmd string  full SSH command string
        " @return string  command with ASKPASS wrapper (or unchanged)
        function! s:wrap_askpass(parsed, ssh_cmd) abort
          if !has_key(a:parsed, 'password') || empty(a:parsed.password)
            return a:ssh_cmd
          endif
          let askpass = tempname() . '.askpass.sh'
          call writefile(['#!/bin/sh', 'echo ' . shellescape(a:parsed.password)], askpass)
          call setfperm(askpass, 'rwx------')
          let rm = 'rm -f ' . shellescape(askpass)
          return 'trap ' . shellescape(rm) . ' EXIT INT TERM HUP; '
                \ . 'SSH_ASKPASS=' . shellescape(askpass)
                \ . ' SSH_ASKPASS_REQUIRE=force '
                \ . a:ssh_cmd
        endfunction

        " --- Unix shells (sh/bash/zsh) ---
        function! DbShell_canonicalize(url) abort
          return substitute(a:url, '^\([^:]\+:///\)\~', '\1' . $HOME, '')
        endfunction
        function! DbShell_input_extension(...) abort
          return 'sh'
        endfunction
        " Build command to execute input file via sh/bash/zsh.
        " Local: runs interpreter directly on the temp file.
        " Remote: pipes temp file via stdin to 'ssh ... interpreter -s'.
        " @param url string  adapter URL
        " @param in string  path to local temp file with script content
        " @return list|string  command for dadbod to execute
        function! DbShell_input(url, in) abort
          let parsed = db#url#parse(a:url)
          let scheme = get(parsed, 'scheme', 'shell')
          let sh = scheme ==# 'shell' ? 'sh' : scheme
          if s:is_remote(parsed)
            let remote_cmd = s:remote_cd(a:url, parsed) . sh . ' -s'
            let ssh_cmd = s:ssh_prefix(parsed) . ' ' . shellescape(remote_cmd)
                  \ . ' < ' . shellescape(a:in)
            return ['sh', '-c', s:wrap_askpass(parsed, ssh_cmd)]
          endif
          let dir = s:resolve_dir(a:url)
          return [sh, '-c', 'cd ' . s:sh_quote(dir) . ' && ' . shellescape(sh) . ' ' . shellescape(a:in)]
        endfunction
        function! DbShell_auth_input() abort
          return v:false
        endfunction

        " --- Windows cmd.exe ---
        function! DbCmd_input_extension(...) abort
          return 'bat'
        endfunction
        " Build command to execute input file via cmd.exe.
        " Local: runs cmd /c on the temp file.
        " Remote: inlines script content into SSH command (cmd has no stdin mode).
        " @param url string  adapter URL
        " @param in string  path to local temp file with script content
        " @return list|string  command for dadbod to execute
        function! DbCmd_input(url, in) abort
          let parsed = db#url#parse(a:url)
          if s:is_remote(parsed)
            let content = join(readfile(a:in), ' & ')
            let remote_cmd = s:remote_cd_cmd(a:url, parsed) . content
            let ssh_cmd = s:ssh_prefix(parsed) . ' ' . shellescape(remote_cmd)
            return ['sh', '-c', s:wrap_askpass(parsed, ssh_cmd)]
          endif
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
        " Build command to execute input file via powershell/pwsh.
        " Local: runs interpreter with -Command on the temp file.
        " Remote: pipes temp file via stdin to 'ssh ... pwsh -Command -'.
        " @param url string  adapter URL
        " @param in string  path to local temp file with script content
        " @return list|string  command for dadbod to execute
        function! DbPwsh_input(url, in) abort
          let parsed = db#url#parse(a:url)
          let scheme = get(parsed, 'scheme', 'pwsh')
          let sh = scheme ==# 'powershell' ? 'powershell' : 'pwsh'
          if s:is_remote(parsed)
            let remote_cmd = s:remote_cd(a:url, parsed) . sh . ' -NoProfile -Command -'
            let ssh_cmd = s:ssh_prefix(parsed) . ' ' . shellescape(remote_cmd)
                  \ . ' < ' . shellescape(a:in)
            return ['sh', '-c', s:wrap_askpass(parsed, ssh_cmd)]
          endif
          let dir = s:resolve_dir(a:url)
          return [sh, '-NoProfile', '-Command',
                \ 'Set-Location ' . s:sh_quote(dir) . '; & ' . shellescape(a:in)]
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

      vim.api.nvim_create_user_command("DBCd", function(opts)
        if opts.args == "" then
          vim.b.db_cwd = nil
          vim.notify("DBCd: reset to URL path", vim.log.levels.INFO)
        else
          vim.b.db_cwd = opts.args
          vim.notify("DBCd: " .. opts.args, vim.log.levels.INFO)
        end
      end, {
        nargs = "?",
        desc = "Override working directory for current buffer",
        complete = function(arg_lead)
          return vim.fn.getcompletion(arg_lead, "dir")
        end,
      })

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
