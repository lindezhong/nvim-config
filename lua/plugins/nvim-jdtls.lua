-- =============================================================================
-- Java LSP + DAP unified configuration via nvim-jdtls plugin.
--
-- This file provides full Java IDE support by delegating to nvim-jdtls, which
-- manages the Eclipse JDT Language Server (jdtls) lifecycle, including:
-- - LSP: code completion, diagnostics, go-to-definition, references, rename, etc.
-- - DAP: debugging with java-debug-adapter and java-test bundles
-- - jdt:// URI handling: navigation into decompiled JDK/library class files
--
-- Why nvim-jdtls instead of plain nvim-lspconfig:
--   jdtls requires special startup parameters (debug bundles, per-project
--   workspace directory, jdt:// URI scheme) that don't fit the standard
--   mason-lspconfig auto-enable flow. nvim-jdtls handles all of this.
--
-- Integration with other modules:
--   - mason-ensure.lua: auto-installs jdtls, java-debug-adapter, java-test
--   - lsp/keymaps.lua: standard LspAttach keymaps apply automatically
--   - nvim-dap.lua: DAP keymaps (F5, F9, etc.) work once DAP configs are set up
--
-- Commands:
--   :JdtUpdateDebugConfig  manually refresh available main class configurations
--
-- Keybindings:
--   F5                     start/continue debugging (via nvim-dap)
-- =============================================================================

-- Register tools for auto-installation via Mason.
-- These are Mason registry package names (not lspconfig names).
require("mason-ensure").add("jdtls")                 -- Java LSP server (Eclipse JDT.LS)
require("mason-ensure").add("java-debug-adapter")    -- Java DAP adapter (Microsoft)
require("mason-ensure").add("java-test")             -- Java test runner (Microsoft)

--- @type LazyPluginSpec[]
return {
  {
    "mfussenegger/nvim-jdtls",
    dependencies = { "mfussenegger/nvim-dap" },  -- DAP must be available for debug bundle init
    ft = "java",                                  -- lazy-load: only when a .java file is opened
    config = function()
      --- @type string Mason installation root directory
      local mason_path = vim.fn.stdpath("data") .. "/mason"
      --- @type string Path to the jdtls Mason package (contains bin/jdtls launcher)
      local jdtls_path = mason_path .. "/packages/jdtls"

      -- Collect debug/test extension JARs that jdtls loads as "bundles".
      -- These enable DAP support inside jdtls (java-debug-adapter provides the
      -- debug protocol bridge; java-test provides test discovery/run).
      --- @type string[] list of absolute paths to JAR files
      local bundles = {}
      --- @type string glob result: path to the debug adapter plugin JAR (single match)
      local debug_jar = vim.fn.glob(
        mason_path .. "/packages/java-debug-adapter/extension/server/com.microsoft.java.debug.plugin-*.jar"
      )
      if debug_jar ~= "" then
        -- Add the debug adapter JAR (enables "Launch" and "Attach" debug configs)
        table.insert(bundles, debug_jar)
      end
      -- Add all java-test JARs (enables "Run Test" / "Debug Test" code lens)
      vim.list_extend(
        bundles,
        vim.fn.glob(mason_path .. "/packages/java-test/extension/server/*.jar", false, true)
      )

      --- Build a fresh jdtls configuration table for the current buffer.
      --- Called each time a java FileType event fires, so root_dir and workspace_dir
      --- are always relative to the current file's project (supports multi-project).
      --- start_or_attach() is idempotent: if a server for this root already runs,
      --- it attaches the buffer to the existing server instead of spawning a new one.
      --- @return table jdtls configuration suitable for require("jdtls").start_or_attach()
      local function make_config()
        -- Detect project root by walking up from the current file looking for build markers.
        -- Falls back to cwd if no marker is found (e.g. standalone .java file).
        --- @type string absolute path to the project root directory
        local root = require("jdtls.setup").find_root({ "gradlew", "mvnw", "pom.xml", "build.gradle", ".git" })
          or vim.fn.getcwd()
        -- Use the root directory's basename as a unique project identifier.
        -- This isolates jdtls workspace metadata per project under the cache dir.
        --- @type string last path component of the project root (e.g. "my-app")
        local project_name = vim.fn.fnamemodify(root, ":p:h:t")
        --- @type string per-project jdtls workspace directory (stores indexes, settings)
        local workspace_dir = vim.fn.stdpath("cache") .. "/jdtls/workspace/" .. project_name
        return {
          -- Command to launch jdtls; "-data" points to the per-project workspace
          cmd = {
            jdtls_path .. "/bin/jdtls",
            "-data", workspace_dir,
          },
          -- Project root directory (jdtls uses this for classpath resolution)
          root_dir = root,
          -- Pass debug/test bundles so jdtls loads them at startup
          init_options = {
            bundles = bundles,
          },
          --- Called when jdtls attaches to a buffer. Triggers async discovery of
          --- runnable main classes and registers them as nvim-dap configurations.
          --- @param _ lsp.Client unused (jdtls client handle)
          --- @param _ integer unused (buffer number)
          on_attach = function(_, _)
            -- 2s delay: jdtls needs time to index the project before it can resolve
            -- main classes. For large Gradle/Maven projects this may not suffice —
            -- use :JdtUpdateDebugConfig to refresh manually after full initialization.
            vim.defer_fn(function()
              require("jdtls.dap").setup_dap_main_class_configs()
            end, 2000)
          end,
        }
      end

      -- Register a FileType autocmd for all future java buffers.
      -- When lazy.nvim loads this plugin (triggered by the first java file's ft event),
      -- that initial event has already passed — so the autocmd below won't fire for the
      -- current buffer. The direct start_or_attach() call below handles the first buffer.
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "java",
        callback = function()
          require("jdtls").start_or_attach(make_config())
        end,
      })

      -- Start jdtls immediately for the current buffer (first java file that triggered load)
      require("jdtls").start_or_attach(make_config())

      -- User command to manually refresh DAP main class configurations.
      -- Useful after adding new @SpringBootApplication or main() methods.
      vim.api.nvim_create_user_command("JdtUpdateDebugConfig", function()
        require("jdtls.dap").setup_dap_main_class_configs()
      end, { desc = "Refresh Java DAP main class configurations" })
    end,
  },
}
