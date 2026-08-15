-- LSP buffer-local keybindings
--
-- All keymaps are set via LspAttach autocmd, so they only activate
-- in buffers where an LSP server is running.

local M = {}

function M.setup()
  local handlers = require("plugins.lsp.handlers")

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
      -- Find references: show in a floating window
      local references = require("plugins.lsp.references").open
      vim.keymap.set("n", "<C-k>", references, opts)
      vim.keymap.set("n", "<C-Up>", references, opts)
      vim.keymap.set("i", "<C-k>", references, opts)
      vim.keymap.set("i", "<C-Up>", references, opts)
      -- Hover documentation: show type info and docs in a float window
      vim.keymap.set("n", "<C-d>", vim.lsp.buf.hover, opts)
      vim.keymap.set("i", "<C-d>", vim.lsp.buf.hover, opts)
      -- Scroll float window without focusing it
      vim.keymap.set({"n", "i"}, "<S-Down>", function()
        handlers.scroll_float(4)
      end, { buffer = args.buf, silent = true })
      vim.keymap.set({"n", "i"}, "<S-Up>", function()
        handlers.scroll_float(-4)
      end, { buffer = args.buf, silent = true })
      -- S-j/S-k: scroll float if open, otherwise fallback to page scroll
      vim.keymap.set("n", "<S-j>", function()
        if not handlers.scroll_float(4) then vim.cmd("normal! \x06") end
      end, { buffer = args.buf, silent = true })
      vim.keymap.set("n", "<S-k>", function()
        if not handlers.scroll_float(-4) then vim.cmd("normal! \x02") end
      end, { buffer = args.buf, silent = true })
      -- Rename symbol: rename all references across the project
      vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
      -- Code action: show available fixes and refactorings
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
      -- Type definition: jump to the type of the symbol under cursor
      vim.keymap.set("n", "<S-b>", vim.lsp.buf.type_definition, opts)
      -- Implementation: jump to the implementation of an interface/abstract
      vim.keymap.set("n", "<Esc><C-b>", vim.lsp.buf.implementation, opts)
      -- Workspace symbols: search symbols across the entire project
      vim.keymap.set("n", "<C-t>", vim.lsp.buf.workspace_symbol, opts)
      -- Document outline: show file symbols in a right-side panel
      vim.keymap.set("n", "<leader>o", handlers.document_outline, opts)
      -- Selection range: progressively expand selection by syntax tree
      vim.keymap.set("n", "<C-s>", vim.lsp.buf.selection_range, opts)
      vim.keymap.set("x", "<C-s>", vim.lsp.buf.selection_range, opts)
      -- Show diagnostics list: open all diagnostics in location list
      vim.keymap.set("n", "<C-e>", vim.diagnostic.setloclist, opts)
      vim.keymap.set("i", "<C-e>", vim.diagnostic.setloclist, opts)
      -- Incoming call tree: show callers of the symbol under cursor
      vim.keymap.set("n", "<C-A-i>", require("plugins.lsp.calltree").open, opts)
    end,
  })
end

return M
