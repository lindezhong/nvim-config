-- Mason: portable package manager for Neovim external tools
--
-- Installs LSP servers, formatters, linters, and other tools
-- into ~/.local/share/nvim/mason/ without polluting system PATH.
--
-- Other plugins declare dependencies at the top of their spec files:
--   require("mason-ensure").add("tool-name")                    generic tools, latest version
--   require("mason-ensure").add("tool-name@1.0.0")              generic tools, pinned version
--   require("mason-ensure").addLsp({ lsp = "server-name" })     LSP servers, latest version
--   require("mason-ensure").addLsp({ lsp = "server-name@1.0" }) LSP servers, pinned version
--   require("mason-ensure").addLsp({ lsp = "server-name", settings = { ... } })  with config

-- Packages listed in local-config skip_mason are excluded from Mason installation
-- but remain enabled (LSP servers are still activated via vim.lsp.enable in lsp/init.lua).
local skip = {}
for _, name in ipairs(require("local-config").skip_mason) do
  skip[name] = true
end

--- @type LazyPluginSpec[]
return {
  -- Mason core: package manager for external tools
  {
    "mason-org/mason.nvim",
    -- init runs before all plugin configs, making mason-installed binaries
    -- available to subsequent plugins (e.g. nvim-treesitter checking tree-sitter)
    init = function()
      -- Prepend Mason bin directory to PATH so mason-installed tools are found by executable()
      vim.env.PATH = vim.fn.stdpath("data") .. "/mason/bin:" .. vim.env.PATH
    end,
    config = function()
      -- Initialize Mason (creates directories, sets up commands like :Mason)
      require("mason").setup()

      -- Read the generic tool list populated by other plugins via mason-ensure.add()
      local tools = require("mason-ensure").tools
      if #tools > 0 then
        -- Fetch the latest package index from the Mason registry
        local registry = require("mason-registry")
        registry.refresh(function()
          -- Iterate over each registered tool and install if not already present
          for _, entry in ipairs(tools) do
            if not skip[entry.name] then
              local ok, pkg = pcall(registry.get_package, entry.name)
              if ok and not pkg:is_installed() and not pkg:is_installing() then
                pkg:install({ version = entry.version })
              end
            end
          end
        end)
      end
    end,
  },
  -- Bridge between Mason and lspconfig: auto-install and enable LSP servers
  {
    "mason-org/mason-lspconfig.nvim",
    -- mason.nvim must be loaded first (provides mason-registry APIs)
    -- nvim-lspconfig must be loaded first (server configs registered via vim.lsp.config)
    dependencies = {
      "mason-org/mason.nvim",
      "neovim/nvim-lspconfig",
    },
    config = function()
      -- Read the LSP server list populated by lsp/init.lua via mason-ensure.addLsp()
      local servers = require("mason-ensure").lsp_servers
      if #servers > 0 then
        -- Build ensure_installed list in "name@version" format for mason-lspconfig
        local ensure_installed = {}
        for _, entry in ipairs(servers) do
          if not skip[entry.name] then
            if entry.version then
              table.insert(ensure_installed, entry.name .. "@" .. entry.version)
            else
              table.insert(ensure_installed, entry.name)
            end
          end
        end
        -- Auto-install listed servers and enable them for matching filetypes
        require("mason-lspconfig").setup({
          ensure_installed = ensure_installed,
        })
      end

    end,
  },
}
