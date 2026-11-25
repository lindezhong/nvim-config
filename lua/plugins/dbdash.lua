-- Data dashboard (lindezhong/dbdash.nvim)
--
-- Runs a query on an interval and renders the result as a table or terminal
-- chart. Driven by YAML config files (database URL, query template, chart).
-- Pure Lua, no Python or database CLIs.
--
-- Config files (:help dbdash-config):
--   - One chart (database / query / show at the top level) or several panels
--     in a grid (panels / layout). Both follow the same rules: top-level bare
--     fields are dashboard-wide (interval, args, layout, title, description,
--     show_countdown); the top-level database / query / show are defaults
--     that each panel can override (a panel's database replaces it whole).
--   - interval refreshes every panel; each panel also refreshes on its own
--     show.interval (else the top-level show.interval).
--   - args are shared by all panels; a panel's query.args are its own and
--     shadow a shared argument of the same name there.
--   - description / show.description: Markdown templates, read with K.
--
-- Commands:
--   :DbDash                   open sidebar listing YAML configs in current directory
--   :DbDashClose              close the sidebar
--   :DbDashStart[!] <file> [name=value ...]  start a dashboard (! asks for every argument;
--                             <panel>.name=value sets one panel's own argument)
--   :DbDashRestart            refresh current dashboard
--   :DbDashStop [file]        stop a dashboard
--   :DbDashList               list all running dashboards
--   :DbDashStatus             show dashboard status and query history
--   :DbDashShowVariables      show template variables for current dashboard
--   :DbDashModifyVariable     interactive variable modification menu
--   :DbDashUpdateVariable <name> <value>  update a specific variable
--   :DbDashResetVariables     reset all variables to defaults
--   :DbDashShowSQL            show rendered query in a floating window
--   :DbDashDescribe           show the description (Markdown) of the dashboard / panel under the cursor
--   :DbDashExport[!] [format] [file]  export the result (csv, tsv, json, markdown)
--   :DbDashStyle <type> <style>  re-render with another style (e.g. line asciichart)
--   :DbDashTrust [allow|deny|remove] [file]  decide about a config that runs Lua
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
--   e   export the result
--   K   show the description (ⓘ marks titles that have one)
--
-- Sidebar keys:
--   Enter  start/open selected dashboard
--   t      stop selected dashboard
--   r      refresh selected dashboard
--   q      close sidebar
--
-- Requirements: Neovim 0.12+; SQLite dashboards need the system libsqlite3.
--
-- Dependencies:
--   None. The K float highlights Markdown with the bundled markdown treesitter
--   parsers; without them (some Windows installs) it falls back to the Vim
--   markdown syntax. The float is a scratch buffer (buftype=nofile), so
--   render-markdown.lua skips it (its nofile override); markup is concealed
--   by the builtin treesitter query (conceallevel=2) instead.
--
-- Behavior notes:
--   - Configs that run Lua (lua://, query.transform, {% lua %}, imported .lua)
--     ask for trust once per config; :DbDashTrust decides without asking.
--   - Dashboards not visible in the current tab page pause and catch up when
--     shown again (dashboard.pause_hidden).
--
-- Options (sidebar size/position/dir, keys, icons, defaults): :help dbdash-setup
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
    -- Track the master branch (no release tag pinning)
    branch = "master",
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
