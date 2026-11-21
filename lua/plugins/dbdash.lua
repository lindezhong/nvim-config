-- Data dashboard (lindezhong/dbdash.nvim)
--
-- Runs a query on an interval and renders the result as a table or terminal
-- chart. Driven by YAML config files (database URL, query template, chart).
-- Pure Lua, no Python or database CLIs; replaces lindezhong/vim-dashboard.
--
-- Commands:
--   :DbDash                   open sidebar listing YAML configs in current directory
--   :DbDashClose              close the sidebar
--   :DbDashStart[!] <file> [name=value ...]  start a dashboard (! asks for every argument)
--   :DbDashRestart            refresh current dashboard
--   :DbDashStop [file]        stop a dashboard
--   :DbDashList               list all running dashboards
--   :DbDashStatus             show dashboard status and query history
--   :DbDashShowVariables      show template variables for current dashboard
--   :DbDashModifyVariable     interactive variable modification menu
--   :DbDashUpdateVariable <name> <value>  update a specific variable
--   :DbDashResetVariables     reset all variables to defaults
--   :DbDashShowSQL            show rendered query in a floating window
--   :DbDashStyle <type> <style>  re-render with another style (e.g. line asciichart)
--
-- Global keys: <leader>ds start, <leader>dr refresh, <leader>dt stop,
--              <leader>dl list, <leader>dd sidebar
--
-- Dashboard buffer keys:
--   a   modify variable interactively
--   A   show all variables
--   r   refresh
--   R   reset variables to defaults
--   s   show rendered query
--
-- Sidebar keys:
--   Enter  start/open selected dashboard
--   t      stop selected dashboard
--   r      refresh selected dashboard
--   q      close sidebar
--
-- Requirements: Neovim 0.12+; SQLite dashboards need the system libsqlite3.
--
-- Options (sidebar size/position/dir, keys, defaults): :help dbdash-setup
--
-- Sessions: session.lua restores running dashboards; changed arguments are
-- kept in "{session_file}.dbdash" via the session hook below.
--
-- Docs: :help dbdash. Examples and the config JSON Schema: <plugin_dir>/example/
--   (run `:echo stdpath("data") .. "/lazy/dbdash.nvim/example/"` to get the path)

--- @type LazyPluginSpec[]
return {
  {
    "lindezhong/dbdash.nvim",
    -- Not lazy-loaded: plugin/dbdash.lua only defines commands, mappings and
    -- autocmds (modules load on first use), and its BufReadCmd autocmd must
    -- exist when session.lua restores dbdash:// buffers at VimEnter.
    lazy = false,
    opts = {
      sidebar = { width = "25%" },  -- 25% of the editor width, computed when opened
    },
    config = function(_, opts)
      local dbdash = require("dbdash")
      dbdash.setup(opts)

      -- ===== Argument persistence (session hook) =====
      -- The session itself restores and restarts dashboards (dbdash:// buffers)
      -- with default arguments; this keeps the changed argument values in
      -- "{session_file}.dbdash" (removed with the session by :Exit).
      require("session").register("dbdash", {
        --- @param session_file string path to the session file
        on_save = function(session_file)
          dbdash.mksession(session_file .. ".dbdash")
        end,
        --- @param session_file string path to the session file
        on_load = function(session_file)
          dbdash.load_session(session_file .. ".dbdash")
        end,
      })
    end,
  },
}
