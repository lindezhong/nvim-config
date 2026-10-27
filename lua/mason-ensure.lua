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

--- @class MasonEnsureEntry
--- @field name string Package name (mason registry name or lspconfig server name)
--- @field version string|nil Optional version constraint (e.g. "0.25.0")
--- @field config table|nil LSP config table passed to vim.lsp.config()

--- @class MasonEnsure
--- @field tools MasonEnsureEntry[] List of generic Mason tools
--- @field lsp_servers MasonEnsureEntry[] List of LSP servers in lspconfig format
local M = { tools = {}, lsp_servers = {}, _seen_tools = {}, _seen_lsp = {} }

--- Parse "name@version" format into name and version components.
--- If no "@" is present, version is nil (install latest).
--- @param spec string Package spec, e.g. "debugpy" or "debugpy@2.0.0"
--- @return string name Package name
--- @return string|nil version Version constraint or nil for latest
local function parse(spec)
  -- Split on the first "@" character
  local name, version = spec:match("^([^@]+)@(.+)$")
  if name then
    return name, version
  end
  -- No version specified, install latest
  return spec, nil
end

--- Register a generic Mason tool for auto-installation.
--- Supports optional version pinning with "@" syntax (e.g. "debugpy@v2.0.0").
--- Browse available packages: https://github.com/mason-org/mason-registry/tree/main/packages
--- Or run :Mason in Neovim to search interactively.
--- Version: check the source.id field in the package's package.yaml in mason-registry,
--- it points to the upstream repo (e.g. pkg:github/microsoft/debugpy@v2.0.0),
--- available versions are the release tags of that upstream repo.
--- @param spec string Mason registry package name, optionally with @version
function M.add(spec)
  local name, version = parse(spec)
  if M._seen_tools[name] then return end
  M._seen_tools[name] = true
  table.insert(M.tools, { name = name, version = version })
end

--- Register an LSP server for auto-installation via mason-lspconfig.
--- Supports optional version pinning with "@" syntax (e.g. "vtsls@0.2.6").
--- Uses lspconfig server names, mason-lspconfig handles the mapping to Mason package names.
--- Browse available servers: :help lspconfig-all
--- Or see https://github.com/neovim/nvim-lspconfig/blob/master/doc/configs.md
--- Version: find the server's mason package name via :Mason, then check its package.yaml
--- in mason-registry for the upstream repo; available versions are that repo's release tags.
--- @param spec { lsp: string, [string]: any } Table with lsp name and optional config fields
function M.addLsp(spec)
  local name, version = parse(spec.lsp)
  if M._seen_lsp[name] then return end
  M._seen_lsp[name] = true
  local config = nil
  for k, v in pairs(spec) do
    if k ~= "lsp" then
      if not config then config = {} end
      config[k] = v
    end
  end
  table.insert(M.lsp_servers, { name = name, version = version, config = config })
end

return M
