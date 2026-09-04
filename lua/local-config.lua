-- Machine-local config reader.
-- Reads lua/local.lua (gitignored) and merges into default structure.
-- local.lua supports native vim configuration (vim.g, vim.opt, autocmds, etc.)
-- in addition to returning a config table.
--
-- Example lua/local.lua:
--   -- Native vim configuration (executed when local.lua is loaded)
--   vim.g.clipboard = {
--     name = "OSC 52",
--     copy = {
--       ["+"] = require("vim.ui.clipboard.osc52").copy("+"),
--       ["*"] = require("vim.ui.clipboard.osc52").copy("*"),
--     },
--     paste = {
--       ["+"] = function() return 0 end,
--       ["*"] = function() return 0 end,
--     },
--   }
--
--   -- Config table returned for structured settings
--   return {
--     java_runtimes = {
--       { name = "JavaSE-17", path = "/usr/lib/jvm/java-17-openjdk" },
--     },
--     skip_mason = { "clangd" },
--     extra_lsp = {
--       { lsp = "gopls" },
--       { lsp = "rust_analyzer", settings = {
--           ["rust-analyzer"] = {
--             cargo = { allFeatures = true },
--             checkOnSave = { command = "clippy" },
--           },
--         },
--       },
--     },
--   }

---@class JavaRuntime
---@field name "JavaSE-1.8"|"JavaSE-9"|"JavaSE-10"|"JavaSE-11"|"JavaSE-12"|"JavaSE-13"|"JavaSE-14"|"JavaSE-15"|"JavaSE-16"|"JavaSE-17"|"JavaSE-18"|"JavaSE-19"|"JavaSE-20"|"JavaSE-21"|"JavaSE-22"|"JavaSE-23" Eclipse ExecutionEnvironment name, must match project's target Java version
---@field path string absolute path to JDK root directory, e.g. "/opt/jdk8"

---@class LocalConfig
---@field java_runtimes JavaRuntime[] Local JDK installations registered to jdtls so it can compile projects targeting different Java versions (used by plugins/nvim-jdtls.lua → settings.java.configuration.runtimes)
---@field skip_mason string[] Mason package names (or lspconfig server names) to skip installing, for environments where certain packages fail to build (e.g. {"clangd"}); skipped LSP servers are still enabled if the binary is found on system PATH
---@field extra_lsp { lsp: string, [string]: any }[] Additional LSP servers as { lsp = "name", ...config }; installed via Mason and enabled like built-in servers; config fields are passed to vim.lsp.config(); if also in skip_mason, Mason installation is skipped but the server is still enabled if the binary is found on system PATH

local ok, cfg = pcall(require, "local")
if not ok then cfg = {} end

---@type LocalConfig
return {
  java_runtimes = cfg.java_runtimes or {},
  skip_mason = cfg.skip_mason or {},
  extra_lsp = cfg.extra_lsp or {},
}
