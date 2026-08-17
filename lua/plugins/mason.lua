-- Mason: portable package manager for Neovim external tools
--
-- Installs LSP servers, formatters, linters, and other tools
-- into ~/.local/share/nvim/mason/ without polluting system PATH.
--
-- Other plugins declare dependencies at the top of their spec files:
--   require("mason-ensure").add("tool-name")       generic tools (tree-sitter-cli, stylua, etc.)
--   require("mason-ensure").addLsp("server-name")   LSP servers (via mason-lspconfig)

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
          for _, name in ipairs(tools) do
            local ok, pkg = pcall(registry.get_package, name)
            if ok and not pkg:is_installed() then
              pkg:install()
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
        -- Auto-install listed servers and enable them for matching filetypes
        require("mason-lspconfig").setup({
          ensure_installed = servers,
        })
      end
    end,
  },
}
