-- Data dashboard (lindezhong/vim-dashboard)
--
-- Database-connected data dashboard rendered as terminal charts.
-- Driven by YAML config files with SQL queries and chart type definitions.
--
-- Commands:
--   :Dashboard                open sidebar listing YAML configs in current directory
--   :DashboardStart <file>    start a dashboard from a YAML config
--   :DashboardRestart         refresh current dashboard
--   :DashboardStop [file]     stop a dashboard
--   :DashboardList            list all running dashboards
--   :DashboardStatus          show dashboard status
--   :DashboardClose           close the sidebar browser
--   :DashboardShowVariables   show template variables for current dashboard
--   :DashboardModifyVariable  interactive variable modification menu
--   :DashboardUpdateVariable <name> <value>  update a specific variable
--   :DashboardResetVariables  reset all variables to defaults
--   :DashboardShowSQL         show rendered SQL in a floating window
--
-- Dashboard buffer keys:
--   a   modify variable interactively
--   A   show all variables
--   r   restart/refresh
--   R   reset variables to defaults
--   s   show rendered SQL
--
-- Sidebar keys:
--   Enter  start/open selected dashboard
--   t      stop selected dashboard
--   r      restart selected dashboard
--   q      close sidebar
--
-- Requirements:
--   Build:   python3, python3-venv (Debian/Ubuntu: sudo apt install python3-venv)
--            Network access for pip install (or pre-configured pip mirror)
--   Runtime: Neovim python3 provider (pip3 install pynvim)
--
-- If build fails (e.g. network timeout), manually run:
--   :Lazy build vim-dashboard
-- Or run install.py directly in the plugin directory:
--   cd <plugin_dir> && python3 install.py
--
-- YAML config examples: <plugin_dir>/example/
--   (run `:echo stdpath("data") .. "/lazy/vim-dashboard/example/"` to get the path)

--- @type LazyPluginSpec[]
return {
  {
    "lindezhong/vim-dashboard",
    build = "echo N | python3 install.py",
    config = function(plugin)
      -- All checks deferred to first use (no startup overhead)
      if vim.fn.has("python3") ~= 1 then
        vim.notify("vim-dashboard: Neovim python3 provider not available (pip3 install pynvim)", vim.log.levels.ERROR)
        return
      end
      local venv_python = plugin.dir .. "/venv/bin/python"
      if vim.fn.executable(venv_python) ~= 1 then
        vim.notify("vim-dashboard: venv not found, run :Lazy build vim-dashboard", vim.log.levels.ERROR)
        return
      end
      vim.fn.system({ venv_python, "-c", "import jinja2, yaml, rich" })
      if vim.v.shell_error ~= 0 then
        vim.notify("vim-dashboard: dependencies missing, run :Lazy build vim-dashboard", vim.log.levels.ERROR)
      end
    end,
    cmd = {
      "Dashboard",
      "DashboardStart",
      "DashboardRestart",
      "DashboardStop",
      "DashboardList",
      "DashboardStatus",
      "DashboardClose",
      "DashboardShowVariables",
      "DashboardModifyVariable",
      "DashboardUpdateVariable",
      "DashboardResetVariables",
      "DashboardShowSQL",
    },
  },
}
