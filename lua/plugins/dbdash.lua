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
    opts = {},
  },
}
