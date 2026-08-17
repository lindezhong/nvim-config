-- Shared dependency registry for Mason tool installation
--
-- Data-passing module that collects tool names from plugin configs at require-time.
-- Plugin configs call add() / addLsp() at the top level (before lazy.nvim loads plugins),
-- then mason.lua reads the populated lists during its config phase to auto-install them.
--
-- Execution order:
--   1. lazy.nvim scans lua/plugins/, requiring each file -> top-level add()/addLsp() calls run
--   2. lazy.nvim resolves dependencies and loads plugins -> mason config reads the lists
--
-- This module must be separate from lua/plugins/mason.lua because lazy spec files
-- must return plugin spec tables and cannot export custom functions.

--- @class MasonEnsure
--- @field tools string[] List of generic Mason tool names (e.g. "tree-sitter-cli")
--- @field lsp_servers string[] List of LSP server names in lspconfig format (e.g. "lua_ls")
local M = { tools = {}, lsp_servers = {} }

--- Register a generic Mason tool for auto-installation.
--- Uses Mason registry package names (e.g. "tree-sitter-cli", "stylua").
--- Browse available packages: https://github.com/mason-org/mason-registry/tree/main/packages
--- Or run :Mason in Neovim to search interactively.
--- @param name string Mason registry package name
function M.add(name)
  table.insert(M.tools, name)
end

--- Register an LSP server for auto-installation via mason-lspconfig.
--- Uses lspconfig server names (e.g. "vtsls", "lua_ls"), mason-lspconfig
--- handles the mapping to Mason package names internally.
--- Browse available servers: :help lspconfig-all
--- Or see https://github.com/neovim/nvim-lspconfig/blob/master/doc/configs.md
--- @param name string lspconfig server name
function M.addLsp(name)
  table.insert(M.lsp_servers, name)
end

return M
