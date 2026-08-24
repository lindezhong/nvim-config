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

      -- Auto-trigger signature help when typing "(" or ","
      -- Shows function parameter info in a float (all overloads, current param highlighted).
      -- Uses a per-buffer table to merge trigger characters from all attached clients
      -- and creates at most one TextChangedI autocmd per buffer.
      local sig_trigger_bufs = {} --- @type table<integer, table<string, boolean>>
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          local client = vim.lsp.get_client_by_id(args.data.client_id)
          if not client then return end
          local triggers = vim.tbl_get(
            client, "server_capabilities", "signatureHelpProvider", "triggerCharacters"
          )
          if not triggers or #triggers == 0 then return end
          local bufnr = args.buf
          if not sig_trigger_bufs[bufnr] then
            -- First client with signature triggers on this buffer: create autocmd
            sig_trigger_bufs[bufnr] = {}
            vim.api.nvim_create_autocmd("TextChangedI", {
              buffer = bufnr,
              callback = function()
                local col = vim.api.nvim_win_get_cursor(0)[2]
                if col == 0 then return end
                local char = vim.api.nvim_get_current_line():sub(col, col)
                if sig_trigger_bufs[bufnr][char] then
                  vim.lsp.buf.signature_help()
                end
              end,
            })
            vim.api.nvim_create_autocmd("BufDelete", {
              buffer = bufnr,
              once = true,
              callback = function() sig_trigger_bufs[bufnr] = nil end,
            })
          end
          -- Merge this client's trigger characters into the buffer set
          for _, ch in ipairs(triggers) do
            sig_trigger_bufs[bufnr][ch] = true
          end
        end,
      })

      -- vtsls: auto-insert function call snippets with parameter placeholders,
      -- and use bundled TypeScript lib for go-to-definition on built-in types
      local vtsls_settings = {
        typescript = { suggest = { completeFunctionCalls = true } },
        javascript = { suggest = { completeFunctionCalls = true } },
      }
      local vtsls_tsdk = vim.fn.glob(
        vim.fn.stdpath("data") .. "/mason/packages/vtsls/**/typescript/lib", false, true
      )[1]
      if vtsls_tsdk then
        vtsls_settings.typescript.tsdk = vtsls_tsdk
      end
      vim.lsp.config("vtsls", { settings = vtsls_settings })

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

      -- ===== LSP progress notifications =====
      -- Show LSP loading progress in the command line only during initial workspace
      -- initialization. Once all progress tokens for a client complete, subsequent
      -- progress events (e.g. from opening new files) are suppressed. Messages are
      -- display-only (not recorded in :messages) and auto-cleared after 60 seconds.
      -- State is reset on LspDetach so restarted servers show progress again.

      --- @type table<integer, table<string|integer, boolean>>
      --- Maps client_id -> set of currently active progress token ids.
      local lsp_active_tokens = {}

      --- @type table<integer, boolean>
      --- Maps client_id -> true once the client's initial load is complete.
      local lsp_initialized = {}

      --- @type uv_timer_t
      --- Single shared timer used to clear the command line after the last message.
      local lsp_clear_timer = vim.uv.new_timer()

      --- Display a message in the command line and schedule auto-clear after 60s.
      --- Each call resets the timer so only the last message triggers the clear.
      --- @param msg string  The message to display
      local function lsp_echo(msg)
        -- Show the message without recording it in :messages history
        vim.api.nvim_echo({{ msg }}, false, {})
        -- Reset the auto-clear timer (single-shot, 60 seconds)
        lsp_clear_timer:stop()
        lsp_clear_timer:start(60000, 0, vim.schedule_wrap(function()
          -- Clear the command line without adding to history
          vim.api.nvim_echo({{""}}, false, {})
        end))
      end

      -- LspProgress: track progress tokens and display during initial load only
      vim.api.nvim_create_autocmd("LspProgress", {
        callback = function(ev)
          local data = ev.data
          -- Guard: ensure progress data is present
          if not data or not data.params then return end
          local value = data.params.value
          if not value then return end
          --- @type integer
          local client_id = data.client_id
          --- @type string|integer
          local token = data.params.token
          -- Suppress all progress after initial load is complete
          if lsp_initialized[client_id] then return end

          -- Initialize the token set for this client on first event
          if not lsp_active_tokens[client_id] then
            lsp_active_tokens[client_id] = {}
          end

          if value.kind == "begin" then
            -- Register a new active progress token
            lsp_active_tokens[client_id][token] = true
          elseif value.kind == "end" then
            -- Remove completed token from active set
            lsp_active_tokens[client_id][token] = nil
            -- When all tokens complete, mark client as initialized
            if not next(lsp_active_tokens[client_id]) then
              lsp_initialized[client_id] = true
              lsp_active_tokens[client_id] = nil
              local client = vim.lsp.get_clients({ id = client_id })[1]
              local name = client and client.name or "LSP"
              lsp_echo("[" .. name .. "] initialized")
            end
            return
          end

          -- Display in-progress message: "[name] title message (percentage%)"
          local client = vim.lsp.get_clients({ id = client_id })[1]
          local name = client and client.name or "LSP"
          local msg = "[" .. name .. "] " .. (value.title or "")
          -- Append message text if it differs from title (avoid duplication)
          if value.message and value.message ~= value.title then
            msg = msg .. " " .. value.message
          end
          -- Append percentage only when meaningful (> 0%)
          if value.percentage and value.percentage > 0 then
            msg = msg .. " (" .. value.percentage .. "%)"
          end
          lsp_echo(msg)
        end,
      })

      -- LspAttach: notify when a language server attaches to a buffer
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(ev)
          local client = vim.lsp.get_clients({ id = ev.data.client_id })[1]
          if client then
            lsp_echo("[LSP] " .. client.name .. " attached")
          end
        end,
      })

      -- LspDetach: clear initialization state so a restarted server shows progress again
      vim.api.nvim_create_autocmd("LspDetach", {
        callback = function(ev)
          lsp_initialized[ev.data.client_id] = nil
          lsp_active_tokens[ev.data.client_id] = nil
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
