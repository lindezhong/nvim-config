-- LSP (Language Server Protocol) configuration
--
-- This file sets up the full LSP environment:
-- 1. Mason: portable package manager for LSP servers, linters, and formatters
-- 2. mason-lspconfig: automatically install and enable configured LSP servers
-- 3. Completion: integrates nvim-cmp capabilities so LSP provides rich completions
-- 4. Servers: vtsls (TypeScript/JavaScript), jsonls (JSON)
-- 5. Progress: displays LSP loading/indexing status in the command line
-- 6. Keybindings: buffer-local, active only when LSP attaches

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

      vim.lsp.config("*", {
        capabilities = capabilities,
      })

      require("mason-lspconfig").setup({
        -- LSP servers to auto-install
        ensure_installed = { "vtsls", "jsonls" },
        automatic_enable = {
          -- Exclude ts_ls to avoid conflict with vtsls
          exclude = { "ts_ls" },
        },
      })

      -- Float window highlight (make hover/signature popups visible)
      vim.api.nvim_set_hl(0, "NormalFloat", { ctermbg = "LightMagenta", ctermfg = "DarkGray" })
      vim.api.nvim_set_hl(0, "FloatBorder", { ctermbg = "LightMagenta", ctermfg = "DarkGray" })

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

      -- Set keybindings when LSP attaches to a buffer
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          local client = vim.lsp.get_clients({ id = args.data.client_id })[1]
          if client then
            vim.notify("[LSP] " .. client.name .. " attached", vim.log.levels.INFO)
          end
          local opts = { buffer = args.buf }
          -- Go to definition: jump to where the symbol is defined
          vim.keymap.set("n", "<C-b>", vim.lsp.buf.definition, opts)
          vim.keymap.set("n", "<C-j>", vim.lsp.buf.definition, opts)
          vim.keymap.set("n", "<C-Down>", vim.lsp.buf.definition, opts)
          vim.keymap.set("i", "<C-j>", vim.lsp.buf.definition, opts)
          vim.keymap.set("i", "<C-Down>", vim.lsp.buf.definition, opts)
          -- Find references: list all locations where the symbol is used
          vim.keymap.set("n", "<C-k>", vim.lsp.buf.references, opts)
          vim.keymap.set("n", "<C-Up>", vim.lsp.buf.references, opts)
          vim.keymap.set("i", "<C-k>", vim.lsp.buf.references, opts)
          vim.keymap.set("i", "<C-Up>", vim.lsp.buf.references, opts)
          -- Hover documentation: show type info and docs in a float window
          -- Float window has no padding by default, border acts as visual padding
          -- border: "single" thin line, "double" double line, "rounded" round corners, "shadow" shadow block
          vim.keymap.set("n", "<C-d>", function()
            vim.lsp.buf.hover({ border = "rounded" })
          end, opts)
          vim.keymap.set("i", "<C-d>", function()
            vim.lsp.buf.hover({ border = "rounded" })
          end, opts)
          -- Rename symbol: rename all references of the symbol across the project
          vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
          -- Code action: show available fixes and refactorings at cursor position
          vim.keymap.set("n", "<Esc><S-i>", vim.lsp.buf.code_action, opts)
          vim.keymap.set("n", "<Esc><CR>", vim.lsp.buf.code_action, opts)
          vim.keymap.set("i", "<Esc><S-i>", vim.lsp.buf.code_action, opts)
          vim.keymap.set("i", "<Esc><CR>", vim.lsp.buf.code_action, opts)
          -- Format file: format the entire buffer using LSP formatter
          vim.keymap.set("n", "<leader>f", vim.lsp.buf.format, opts)
          -- Format selection: format visual selection and exit visual mode
          vim.keymap.set("v", "<leader>f", function()
            vim.lsp.buf.format()
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
          end, opts)
          -- Previous diagnostic: jump to the previous error/warning
          vim.keymap.set("n", "[g", vim.diagnostic.goto_prev, opts)
          -- Next diagnostic: jump to the next error/warning
          vim.keymap.set("n", "]g", vim.diagnostic.goto_next, opts)
          -- Show diagnostics list: open all diagnostics in location list
          vim.keymap.set("n", "<C-e>", vim.diagnostic.setloclist, opts)
          vim.keymap.set("i", "<C-e>", vim.diagnostic.setloclist, opts)
        end,
      })
    end,
  },
}
