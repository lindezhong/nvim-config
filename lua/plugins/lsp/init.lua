-- LSP (Language Server Protocol) configuration
--
-- Plugin declarations and server setup:
-- 1. Server configs: vtsls, jsonls, lua_ls, pyright, clangd, bashls,
--    html, cssls, yamlls, lemminx (Java handled by nvim-jdtls plugin)
-- 2. Servers are auto-installed via mason-ensure and auto-enabled via mason-lspconfig
-- 3. Semantic tokens disabled to prevent overriding syntax colors
--
-- :LspInfo    show attached LSP clients for current buffer
-- :LspLog     open LSP client log file

-- Register LSP servers for auto-installation via Mason
-- Uses lspconfig names; mason-lspconfig maps them to Mason package names
require("mason-ensure").addLsp("vtsls")     -- TypeScript/JavaScript
require("mason-ensure").addLsp("jsonls")    -- JSON
require("mason-ensure").addLsp("lua_ls")    -- Lua
require("mason-ensure").addLsp("pyright")   -- Python
require("mason-ensure").addLsp("clangd")    -- C/C++
require("mason-ensure").addLsp("bashls")    -- Shell (Bash/Sh)
require("mason-ensure").addLsp("html")      -- HTML
require("mason-ensure").addLsp("cssls")     -- CSS/SCSS/Less
require("mason-ensure").addLsp("yamlls")    -- YAML
require("mason-ensure").addLsp("lemminx")   -- XML

return {
  -- Core LSP configuration (server settings, capabilities, keymaps)
  {
    "neovim/nvim-lspconfig",
    config = function()
      -- Disable LSP semantic tokens for all clients on attach.
      -- Without this, LSP servers send semantic token data that overrides
      -- treesitter/syntax colors after the server starts, causing a visible color flash.
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          -- Get the LSP client that just attached to this buffer
          local client = vim.lsp.get_client_by_id(args.data.client_id)
          if client then
            -- Remove semantic tokens capability so the client never sends token data
            client.server_capabilities.semanticTokensProvider = nil
          end
        end,
      })

      -- vtsls: use bundled TypeScript lib as fallback for go-to-definition on built-in types
      -- (e.g. jumping to the definition of Promise, Array, etc.)
      local vtsls_tsdk = vim.fn.glob(
        vim.fn.stdpath("data") .. "/mason/packages/vtsls/**/typescript/lib", false, true
      )[1]
      if vtsls_tsdk then
        vim.lsp.config("vtsls", {
          settings = { typescript = { tsdk = vtsls_tsdk } },
        })
      end

      -- Configure lua_ls to recognize Neovim runtime API
      -- (vim.*, vim.api.*, etc. for plugin/config development)
      vim.lsp.config("lua_ls", {
        settings = {
          Lua = {
            -- Use LuaJIT runtime (Neovim's embedded Lua engine)
            runtime = { version = "LuaJIT" },
            workspace = {
              -- Add Neovim runtime files to workspace library for API completion
              library = { vim.env.VIMRUNTIME },
              -- Disable third-party library detection prompts
              checkThirdParty = false,
            },
          },
        },
      })

      -- Display LSP loading progress in command line
      -- (e.g. "[lua_ls] Indexing workspace 45%")
      vim.api.nvim_create_autocmd("LspProgress", {
        callback = function(ev)
          -- Extract progress data from the event
          local data = ev.data
          if not data or not data.params then return end
          local value = data.params.value
          if not value then return end
          -- Get the client name for display prefix
          local client = vim.lsp.get_clients({ id = data.client_id })[1]
          local name = client and client.name or "LSP"
          -- Build progress message: "[client] title message (percentage%)"
          local msg = "[" .. name .. "] " .. (value.title or "")
          if value.message then
            msg = msg .. " " .. value.message
          end
          if value.percentage then
            msg = msg .. " (" .. value.percentage .. "%)"
          end
          -- Show "done" when progress completes
          if value.kind == "end" then
            msg = "[" .. name .. "] " .. (value.title or "") .. " done"
          end
          -- Display in command line without adding to message history
          vim.api.nvim_echo({{ msg }}, false, {})
        end,
      })

      -- ===== Internal modules (lua/plugins/lsp/*) =====

      -- Diagnostic display settings (signs, float-on-hold, no virtual text)
      require("plugins.lsp.config").setup()
      -- Float window highlights for hover/signature popups
      require("plugins.lsp.highlights").setup()
      -- Set up buffer-local keybindings when LSP attaches
      require("plugins.lsp.keymaps").setup()
    end,
  },
}
