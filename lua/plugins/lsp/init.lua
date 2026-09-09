-- LSP (Language Server Protocol) configuration
--
-- Plugin declarations and server setup:
-- 1. Server configs: vtsls, jsonls, lua_ls, pyright, clangd, bashls,
--    html, cssls, yamlls, lemminx, rust_analyzer (Java handled by nvim-jdtls plugin)
-- 2. Servers are auto-installed via mason-ensure, enabled via vim.lsp.enable()
-- 3. Semantic tokens disabled to prevent overriding syntax colors
--
-- :LspInfo    show attached LSP clients for current buffer
-- :LspLog     open LSP client log file

-- Register LSP servers for auto-installation via Mason
-- Uses lspconfig names; mason-lspconfig maps them to Mason package names
local ensure = require("mason-ensure")
ensure.addLsp({ lsp = "vtsls", settings = (function() -- TypeScript/JavaScript
  local s = {
    typescript = { suggest = { completeFunctionCalls = true } },
    javascript = { suggest = { completeFunctionCalls = true } },
  }
  local tsdk = vim.fn.glob(
    vim.fn.stdpath("data") .. "/mason/packages/vtsls/**/typescript/lib", false, true
  )[1]
  if tsdk then s.typescript.tsdk = tsdk end
  return s
end)() })
ensure.addLsp({ lsp = "jsonls" })    -- JSON
ensure.addLsp({ lsp = "lua_ls", settings = { -- Lua
  Lua = {
    runtime = { version = "LuaJIT" },
    workspace = {
      library = { vim.env.VIMRUNTIME },
      checkThirdParty = false,
    },
  },
} })
ensure.addLsp({ lsp = "pyright" })   -- Python
ensure.addLsp({ lsp = "clangd" })   -- C/C++
ensure.addLsp({ lsp = "bashls" })   -- Shell (Bash/Sh)
ensure.addLsp({ lsp = "html" })     -- HTML
ensure.addLsp({ lsp = "cssls" })    -- CSS/SCSS/Less
ensure.addLsp({ lsp = "yamlls" })   -- YAML
ensure.addLsp({ lsp = "lemminx" })  -- XML
ensure.addLsp({ lsp = "rust_analyzer", settings = { -- Rust
  ["rust-analyzer"] = {
    cargo = { allFeatures = true },
    -- Run clippy (instead of plain check) on save for richer diagnostics
    checkOnSave = true,
    check = { command = "clippy" },
  },
} })

-- Machine-local LSP servers from lua/local.lua
for _, spec in ipairs(require("local-config").extra_lsp) do
  ensure.addLsp(spec)
end

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

      -- Apply LSP configs registered via addLsp
      for _, entry in ipairs(ensure.lsp_servers) do
        if entry.config then
          vim.lsp.config(entry.name, entry.config)
        end
      end

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

      -- :LspStatus — show indexing state of all attached LSP clients
      vim.api.nvim_create_user_command("LspStatus", function()
        local clients = vim.lsp.get_clients({ bufnr = 0 })
        if #clients == 0 then
          vim.notify("No LSP clients attached", vim.log.levels.INFO)
          return
        end
        for _, client in ipairs(clients) do
          local status = lsp_initialized[client.id] and "ready" or "indexing..."
          vim.notify("[" .. client.name .. "] " .. status, vim.log.levels.INFO)
        end
      end, { desc = "Show LSP indexing status" })

      -- Enable skip_mason servers found on system PATH.
      -- Must run inside config (after lspconfig loads) so vim.lsp.config[name].cmd
      -- is populated — the cmd[1] gives the real binary name (e.g. "lua-language-server"
      -- for lspconfig name "lua_ls").
      local skip = {}
      for _, name in ipairs(require("local-config").skip_mason) do
        skip[name] = true
      end
      for _, entry in ipairs(ensure.lsp_servers) do
        if skip[entry.name] then
          local cfg = vim.lsp.config[entry.name]
          local bin = cfg and cfg.cmd and cfg.cmd[1] or entry.name
          if vim.fn.executable(bin) == 1 then
            vim.lsp.enable(entry.name)
          end
        end
      end

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
