-- LSP (Language Server Protocol) configuration
--
-- Plugin declarations and server setup:
-- 1. Mason: portable package manager for LSP servers
-- 2. mason-lspconfig: auto-install and enable configured servers
-- 3. Server configs: vtsls (TypeScript), jsonls (JSON)
-- 4. Calltree: incoming call hierarchy viewer (keybinding in keymaps.lua)

return {
  -- LSP server manager
  {
    "williamboman/mason.nvim",
    config = function()
      require("mason").setup()
    end,
  },
  -- LSP configuration collection
  {
    "neovim/nvim-lspconfig",
  },
  -- Bridge between Mason and lspconfig, auto-install and enable LSP servers
  {
    "williamboman/mason-lspconfig.nvim",
    dependencies = {
      "williamboman/mason.nvim",
      "neovim/nvim-lspconfig",
      "hrsh7th/cmp-nvim-lsp",
    },
    config = function()
      -- Inject cmp completion capabilities into all LSP servers
      local capabilities = require("cmp_nvim_lsp").default_capabilities()
      vim.lsp.config("*", { capabilities = capabilities })

      -- vtsls: use bundled TypeScript lib as fallback for go-to-definition on built-in types
      local vtsls_tsdk = vim.fn.glob(
        vim.fn.stdpath("data") .. "/mason/packages/vtsls/**/typescript/lib", false, true
      )[1]
      if vtsls_tsdk then
        vim.lsp.config("vtsls", {
          settings = { typescript = { tsdk = vtsls_tsdk } },
        })
      end

      require("mason-lspconfig").setup({
        -- LSP servers to auto-install
        ensure_installed = { "vtsls", "jsonls" },
        automatic_enable = {
          -- Exclude ts_ls to avoid conflict with vtsls
          exclude = { "ts_ls" },
        },
      })

      -- Float window highlights for hover/signature popups
      require("plugins.lsp.highlights").setup()

      -- Display LSP loading progress in command line
      vim.api.nvim_create_autocmd("LspProgress", {
        callback = function(ev)
          local data = ev.data
          if not data or not data.params then return end
          local value = data.params.value
          if not value then return end
          local client = vim.lsp.get_clients({ id = data.client_id })[1]
          local name = client and client.name or "LSP"
          local msg = "[" .. name .. "] " .. (value.title or "")
          if value.message then
            msg = msg .. " " .. value.message
          end
          if value.percentage then
            msg = msg .. " (" .. value.percentage .. "%)"
          end
          if value.kind == "end" then
            msg = "[" .. name .. "] " .. (value.title or "") .. " done"
          end
          vim.api.nvim_echo({{ msg }}, false, {})
        end,
      })

      -- Set up buffer-local keybindings when LSP attaches
      require("plugins.lsp.keymaps").setup()
    end,
  },
}
