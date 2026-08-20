-- =============================================================================
-- DAP (Debug Adapter Protocol) plugin configuration for Neovim.
--
-- This file defines the complete debugging setup including debug adapters,
-- default launch configurations, keymaps, sign definitions, breakpoint
-- persistence, and the DAP UI integration.
--
-- Supported languages: Python, TypeScript/JavaScript, C/C++, Lua, Shell
-- (Java DAP is handled by nvim-jdtls plugin separately)
--
-- Keybindings:
--   F5          start/continue debugging
--   F4          terminate debugging
--   F6          run to cursor
--   F7/PageDown step into
--   F8/PageUp   step over
--   F10         step out
--   F9          toggle breakpoint
--   <Leader>F9  conditional breakpoint
--   <Leader>F5  toggle DAP UI
-- =============================================================================

-- Register debug adapters for auto-installation via Mason.
-- These names correspond to Mason package registry entries.
require("mason-ensure").add("debugpy")               -- Python debugger
require("mason-ensure").add("js-debug-adapter")      -- JS/TS debugger (Microsoft vscode-js-debug)
require("mason-ensure").add("codelldb")              -- C/C++/Rust debugger (LLDB-based)
require("mason-ensure").add("bash-debug-adapter")    -- Shell script debugger
require("mason-ensure").add("local-lua-debugger-vscode") -- Lua debugger

--- @type LazyPluginSpec[]
return {
  -- =========================================================================
  -- nvim-dap: core Debug Adapter Protocol client
  -- =========================================================================
  {
    "mfussenegger/nvim-dap",
    dependencies = {
      "mfussenegger/nvim-dap-python", -- helper for Python adapter setup
    },
    config = function()
      --- @type dap
      local dap = require("dap")
      --- @type string Mason installation root directory
      local mason_path = vim.fn.stdpath("data") .. "/mason"

      -- ===== Signs =====
      -- Define gutter signs for breakpoint and execution indicators.

      vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DapBreakpointSign" })
      vim.fn.sign_define("DapBreakpointCondition", { text = "◆", texthl = "DapBreakpointSign" })
      vim.fn.sign_define("DapBreakpointRejected", { text = "○", texthl = "DapBreakpointSign" })
      vim.fn.sign_define("DapStopped", { text = "→", texthl = "DapStoppedSign", linehl = "DapStoppedLine" })

      --- Set highlight groups for DAP signs (terminal colors only).
      --- Re-applied on ColorScheme change to survive theme switches.
      --- @return nil
      local function set_dap_highlights()
        vim.api.nvim_set_hl(0, "DapBreakpointSign", { ctermfg = "Red" })
        vim.api.nvim_set_hl(0, "DapStoppedSign", { ctermfg = "Green" })
        vim.api.nvim_set_hl(0, "DapStoppedLine", { ctermbg = "DarkGrey" })
      end
      set_dap_highlights()
      -- Re-apply highlights when colorscheme changes (they get cleared)
      vim.api.nvim_create_autocmd("ColorScheme", { callback = set_dap_highlights })

      -- ===== Adapters =====
      -- Each adapter entry tells nvim-dap how to start/connect to a debug server.

      -- Python: configured via nvim-dap-python (handles virtualenv detection)
      require("dap-python").setup(mason_path .. "/packages/debugpy/venv/bin/python")

      -- TypeScript/JavaScript: js-debug-adapter (pwa-node)
      -- Uses server mode: nvim-dap connects via TCP after launching the executable.
      -- "${port}" is replaced at runtime with an available random port.
      dap.adapters["pwa-node"] = {
        type = "server",       -- connect via TCP socket
        host = "localhost",
        port = "${port}",      -- placeholder: nvim-dap picks a free port
        executable = {
          command = mason_path .. "/bin/js-debug-adapter",
          args = { "${port}" }, -- pass the chosen port to the adapter process
        },
      }

      -- Alias: VSCode launch.json uses "node" as the type name,
      -- so we point it to the same adapter definition.
      dap.adapters.node = dap.adapters["pwa-node"]

      --- Synchronous on_config listener that rewrites "node" type to "pwa-node".
      --- js-debug-adapter standalone only recognizes "pwa-node" internally;
      --- without this rewrite, launch.json configs with type="node" would fail.
      --- @param config dap.Configuration
      --- @return dap.Configuration
      dap.listeners.on_config.node_type_rewrite = function(config)
        if config.type == "node" then
          config.type = "pwa-node"
        end
        return config
      end

      -- C/C++: codelldb (LLDB-based adapter from vadimcn)
      dap.adapters.codelldb = {
        type = "server",
        port = "${port}",
        executable = {
          command = mason_path .. "/bin/codelldb",
          args = { "--port", "${port}" },
        },
      }

      -- Shell: bash-debug-adapter (executable mode — communicates via stdin/stdout)
      dap.adapters.bashdb = {
        type = "executable",
        command = mason_path .. "/bin/bash-debug-adapter",
        name = "bashdb",
      }

      -- Lua: local-lua-debugger-vscode (executable mode)
      -- enrich_config injects the extensionPath if not provided by the user config.
      dap.adapters["local-lua"] = {
        type = "executable",
        command = mason_path .. "/bin/local-lua-debugger-vscode",
        --- Inject extensionPath into config if not already set.
        --- @param config dap.Configuration
        --- @param on_config fun(config: dap.Configuration)
        enrich_config = function(config, on_config)
          if not config["extensionPath"] then
            -- deepcopy to avoid mutating the shared config template
            config = vim.deepcopy(config)
            config.extensionPath = mason_path .. "/packages/local-lua-debugger-vscode/"
          end
          on_config(config)
        end,
      }


      -- ===== Default Configurations =====
      -- Fallback launch configs used when no .vscode/launch.json is present.

      -- Python: launch current file with debugpy (all code, not just "my code")
      dap.configurations.python = {
        {
          name = "Launch: current file",
          type = "python",
          request = "launch",
          program = "${file}",
          cwd = "${workspaceFolder}",
          justMyCode = false, -- step into library code as well
        },
      }

      -- TypeScript: launch current file via node with ts-node ESM loader
      dap.configurations.typescript = {
        {
          name = "Launch: current file (node)",
          type = "pwa-node",
          request = "launch",
          program = "${file}",
          cwd = "${workspaceFolder}",
          runtimeExecutable = "node",
          runtimeArgs = { "--loader", "ts-node/esm" }, -- enable TypeScript execution
          sourceMaps = true,
          -- resolve source maps only within workspace, exclude node_modules
          resolveSourceMapLocations = { "${workspaceFolder}/**", "!**/node_modules/**" },
        },
        {
          name = "Attach to process",
          type = "pwa-node",
          request = "attach",
          processId = require("dap.utils").pick_process, -- interactive PID picker
          cwd = "${workspaceFolder}",
        },
      }

      -- JavaScript: same as TypeScript but without ts-node loader
      dap.configurations.javascript = {
        {
          name = "Launch: current file (node)",
          type = "pwa-node",
          request = "launch",
          program = "${file}",
          cwd = "${workspaceFolder}",
        },
        {
          name = "Attach to process",
          type = "pwa-node",
          request = "attach",
          processId = require("dap.utils").pick_process,
          cwd = "${workspaceFolder}",
        },
      }

      -- C/C++: launch executable or attach to running process
      dap.configurations.c = {
        {
          name = "Launch executable",
          type = "codelldb",
          request = "launch",
          -- prompt user for the executable path at launch time
          program = function()
            return vim.fn.input("Executable path: ", vim.fn.getcwd() .. "/", "file")
          end,
          cwd = "${workspaceFolder}",
          stopOnEntry = false,
        },
        {
          name = "Attach to PID",
          type = "codelldb",
          request = "attach",
          pid = require("dap.utils").pick_process,
        },
      }
      -- C++ shares the same configurations as C
      dap.configurations.cpp = dap.configurations.c

      -- Shell (bash): launch current file with bash-debug-adapter
      dap.configurations.sh = {
        {
          name = "Launch: current file",
          type = "bashdb",
          request = "launch",
          program = "${file}",
          cwd = "${workspaceFolder}",
          -- paths to bashdb internals shipped with the Mason package
          pathBashdb = mason_path .. "/packages/bash-debug-adapter/extension/bashdb_dir/bashdb",
          pathBashdbLib = mason_path .. "/packages/bash-debug-adapter/extension/bashdb_dir",
          pathBash = "bash",
          pathCat = "cat",
          pathMkfifo = "mkfifo",
          pathPkill = "pkill",
          env = {},
          args = {},
        },
      }

      -- Lua: launch current file with local-lua-debugger
      dap.configurations.lua = {
        {
          name = "Launch: current file",
          type = "local-lua",
          request = "launch",
          cwd = "${workspaceFolder}",
          program = {
            lua = "lua",
            file = "${file}",
          },
        },
      }


      -- .vscode/launch.json is read automatically by the built-in
      -- dap.providers.configs["dap.launch.json"] provider (no manual load needed).
      -- js-debug: set outFiles/skipFiles to [] in launch.json — non-empty values
      -- eagerly preload sourcemaps which can timeout on large bundles.
      --
      -- Type mapping: tells nvim-dap which adapter to use for each launch.json
      -- "type" value when opening files of the specified filetypes.
      --- @type table<string, string[]>
      require("dap.ext.vscode").type_to_filetypes = {
        ["node"] = { "javascript", "typescript" },
        ["pwa-node"] = { "javascript", "typescript" },
        ["cppdbg"] = { "c", "cpp" },
        ["codelldb"] = { "c", "cpp" },
        ["python"] = { "python" },
        ["bashdb"] = { "sh" },
        ["lua-local"] = { "lua" },  -- launch.json type name, adapter name is "local-lua"
      }

      -- ===== Defaults =====

      -- Prefer jumping to an existing window already showing the source buffer.
      -- Fixes breakpoint signs showing as rejected (○) when dap tries to
      -- jump in a terminal/dap-ui panel window.
      dap.defaults.fallback.switchbuf = "useopen,usetab"

      -- ===== Keymaps =====

      vim.keymap.set("n", "<F5>", dap.continue, { silent = true, desc = "DAP: continue/start" })
      -- F4: terminate session AND close UI via the on-complete callback.
      -- UI is intentionally NOT closed on process crash/exit (no event_terminated listener),
      -- so error output remains visible. Only this explicit user action closes it.
      --- @return nil
      vim.keymap.set("n", "<F4>", function()
        dap.terminate(nil, nil, function()
          require("dapui").close()
        end)
      end, { silent = true, desc = "DAP: terminate" })
      vim.keymap.set("n", "<F6>", dap.run_to_cursor, { silent = true, desc = "DAP: run to cursor" })
      vim.keymap.set("n", "<F7>", dap.step_into, { silent = true, desc = "DAP: step into" })
      vim.keymap.set("n", "<F8>", dap.step_over, { silent = true, desc = "DAP: step over" })
      vim.keymap.set("n", "<F10>", dap.step_out, { silent = true, desc = "DAP: step out" })
      vim.keymap.set("n", "<PageDown>", dap.step_into, { silent = true, desc = "DAP: step into" })
      vim.keymap.set("n", "<PageUp>", dap.step_over, { silent = true, desc = "DAP: step over" })
      vim.keymap.set("n", "<F9>", dap.toggle_breakpoint, { silent = true, desc = "DAP: toggle breakpoint" })
      -- Conditional breakpoint: prompts for an expression that must be truthy to break
      vim.keymap.set("n", "<Leader><F9>", function()
        vim.ui.input({ prompt = "Breakpoint condition: " }, function(cond)
          if cond then
            dap.set_breakpoint(cond)
          end
        end)
      end, { silent = true, desc = "DAP: conditional breakpoint" })

      -- ===== Breakpoint persistence (session hook) =====
      -- Saves/restores breakpoints across Neovim sessions using the session.lua
      -- hook system. Breakpoints are serialized as JSON to "{session_file}.dap".

      require("session").register("dap", {
        --- Save all current breakpoints to a JSON file alongside the session file.
        --- Wrapped in pcall to avoid breaking session save on any error.
        --- @param session_file string path to the session file
        on_save = function(session_file)
          pcall(function()
            local breakpoints = require("dap.breakpoints")
            --- @type table<string, dap.bp[]> map of filepath -> breakpoint list
            local bps = {}
            -- Iterate all buffers that have breakpoints set
            for buf, buf_bps in pairs(breakpoints.get()) do
              if vim.api.nvim_buf_is_valid(buf) then
                local name = vim.api.nvim_buf_get_name(buf)
                if name ~= "" then
                  -- Key by absolute filepath for cross-session portability
                  bps[name] = buf_bps
                end
              end
            end
            -- Only write the file if there are breakpoints to persist
            if not vim.tbl_isempty(bps) then
              local file = session_file .. ".dap"
              local f = io.open(file, "w")
              if f then
                f:write(vim.fn.json_encode(bps))
                f:close()
              end
            end
          end)
        end,

        --- Restore breakpoints from the JSON file when a session is loaded.
        --- Wrapped in pcall to avoid breaking session load on corrupted data.
        --- @param session_file string path to the session file
        on_load = function(session_file)
          pcall(function()
            local file = session_file .. ".dap"
            -- Skip if no saved breakpoints file exists
            if vim.fn.filereadable(file) == 0 then
              return
            end
            local f = io.open(file, "r")
            if not f then
              return
            end
            local content = f:read("*a")
            f:close()
            -- Safely decode JSON; bail on malformed data
            local ok, bps = pcall(vim.fn.json_decode, content)
            if not ok or type(bps) ~= "table" then
              return
            end
            local breakpoints = require("dap.breakpoints")
            -- Restore each breakpoint: load the buffer and set the breakpoint at its line
            for filepath, buf_bps in pairs(bps) do
              local buf = vim.fn.bufadd(filepath)  -- add buffer (creates if needed)
              vim.fn.bufload(buf)                   -- ensure buffer content is loaded
              for _, bp in ipairs(buf_bps) do
                -- bp contains {line, condition?, hitCondition?, logMessage?}
                breakpoints.set(bp, buf, bp.line)
              end
            end
          end)
        end,
      })
    end,
  },

  -- =========================================================================
  -- nvim-dap-ui: visual debugging interface
  -- Provides variable inspector, call stack, breakpoints list, and REPL panels.
  -- =========================================================================
  {
    "rcarriga/nvim-dap-ui",
    dependencies = {
      "mfussenegger/nvim-dap",
      "nvim-neotest/nvim-nio", -- async IO library required by dap-ui internals
    },
    config = function()
      local dapui = require("dapui")
      local dap = require("dap")

      -- Initialize dap-ui with ASCII icons (no nerd font dependency)
      dapui.setup({
        icons = { expanded = "-", collapsed = "+", current_frame = ">" },
        controls = {
          enabled = true,
          element = "repl", -- show control buttons in the REPL panel
          icons = {
            pause = "▷",       -- pause execution
            play = "▶",        -- continue execution
            step_into = "→",   -- step into function
            step_over = "↷",   -- step over (next line)
            step_out = "←",    -- step out of function
            step_back = "↺",   -- step back
            run_last = "↺",    -- re-run last config
            terminate = "■",   -- terminate session
            disconnect = "×",  -- disconnect adapter
          },
        },
      })

      -- ===== DAP UI lifecycle =====
      -- Strategy: open automatically on session start; NEVER auto-close on process
      -- exit/crash so that error output (e.g. port conflict stack traces) remains
      -- visible for inspection. User closes explicitly via:
      --   F4         → terminate session + close UI (callback in keymap above)
      --   <Leader>F5 → toggle UI visibility (session unaffected)

      --- Open dap-ui panels when the debug adapter signals "initialized".
      --- @param session dap.Session the newly initialized debug session (unused)
      dap.listeners.after.event_initialized.dapui_config = function()
        dapui.open()
      end

      -- Toggle UI visibility without affecting the debug session.
      -- Works both during active sessions (hide panels to focus on code)
      -- and after session ends (dismiss remaining output panels).
      vim.keymap.set("n", "<Leader><F5>", dapui.toggle, { silent = true, desc = "DAP UI: toggle" })

    end,
  },

  -- Python adapter helper (auto-detects virtualenv)
  { "mfussenegger/nvim-dap-python", lazy = true },

  -- Async IO library (required by nvim-dap-ui)
  { "nvim-neotest/nvim-nio", lazy = true },
}
