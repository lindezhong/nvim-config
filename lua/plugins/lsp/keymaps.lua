-- LSP buffer-local keybindings
--
-- All keymaps are set via LspAttach autocmd, so they only activate
-- in buffers where an LSP server is running.
--
-- Navigation:
--   <C-b>/<C-j>/<C-Down>  go to definition (peek if multiple)
--   <C-k>/<C-Up>          find references (floating picker)
--   <S-b>                 go to type definition
--   <A-j>                go to implementation (peek if multiple)
--   <C-t>                 search workspace symbols
--   <leader>o             document outline (right-side panel)
--
-- Documentation & Scroll:
--   <C-d>                 hover documentation (type info and docs)
--   <S-Down>/<S-Up>       scroll float window (4 lines); page scroll if no float
--   <S-j>/<S-k>           scroll float window (full page); page scroll if no float
--
-- Editing:
--   <leader>rn            rename symbol across project
--   <A-S-i>/<A-CR>        code action (fixes and refactorings)
--   <leader>f             format file (normal) or selection (visual)
--   <C-s>                 expand selection by syntax tree (normal/visual)
--
-- Diagnostics:
--   [g                    jump to previous diagnostic
--   ]g                    jump to next diagnostic
--   <C-e>                 open diagnostic float (focusable) or loclist if no diagnostic
--
-- Call Hierarchy:
--   <C-A-i>              show incoming calls (callers)
--   <C-A-o>              show outgoing calls (callees)

local M = {}

function M.setup()
  local handlers = require("plugins.lsp.handlers")
  local lsp = require("plugins.lsp.lsp")

  vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(args)
      local opts = { buffer = args.buf }
      -- Go to definition: jump or show peekview if multiple definitions
      local definition = require("plugins.lsp.definition").open
      vim.keymap.set("n", "<C-b>", definition, opts)
      vim.keymap.set("n", "<C-j>", definition, opts)
      vim.keymap.set("n", "<C-Down>", definition, opts)
      vim.keymap.set("i", "<C-j>", definition, opts)
      vim.keymap.set("i", "<C-Down>", definition, opts)
      -- Find references: show in a floating window
      local references = require("plugins.lsp.references").open
      vim.keymap.set("n", "<C-k>", references, opts)
      vim.keymap.set("n", "<C-Up>", references, opts)
      vim.keymap.set("i", "<C-k>", references, opts)
      vim.keymap.set("i", "<C-Up>", references, opts)
      -- Hover documentation: show type info and docs in a float window
      vim.keymap.set("n", "<C-d>", lsp.hover, opts)
      vim.keymap.set("i", "<C-d>", lsp.hover, opts)
      -- Scroll float window without focusing it; fallback to page scroll
      local ctrl_e = vim.api.nvim_replace_termcodes("4<C-e>", true, false, true)
      local ctrl_y = vim.api.nvim_replace_termcodes("4<C-y>", true, false, true)
      local ctrl_f = vim.api.nvim_replace_termcodes("<C-f>", true, false, true)
      local ctrl_b = vim.api.nvim_replace_termcodes("<C-b>", true, false, true)
      vim.keymap.set("n", "<S-Down>", function()
        if not handlers.scroll_float(ctrl_e) then vim.cmd("normal! " .. ctrl_f) end
      end, { buffer = args.buf, silent = true })
      vim.keymap.set("n", "<S-Up>", function()
        if not handlers.scroll_float(ctrl_y) then vim.cmd("normal! " .. ctrl_b) end
      end, { buffer = args.buf, silent = true })
      vim.keymap.set("i", "<S-Down>", function()
        handlers.scroll_float(ctrl_e)
      end, { buffer = args.buf, silent = true })
      vim.keymap.set("i", "<S-Up>", function()
        handlers.scroll_float(ctrl_y)
      end, { buffer = args.buf, silent = true })
      vim.keymap.set("n", "<S-j>", function()
        if not handlers.scroll_float(ctrl_f) then vim.cmd("normal! " .. ctrl_f) end
      end, { buffer = args.buf, silent = true })
      vim.keymap.set("n", "<S-k>", function()
        if not handlers.scroll_float(ctrl_b) then vim.cmd("normal! " .. ctrl_b) end
      end, { buffer = args.buf, silent = true })
      -- Rename symbol: rename all references across the project
      vim.keymap.set("n", "<leader>rn", lsp.rename, opts)
      -- Code action: show available fixes and refactorings
      vim.keymap.set("n", "<A-S-i>", lsp.code_action, opts)
      vim.keymap.set("n", "<A-CR>", lsp.code_action, opts)
      vim.keymap.set("i", "<A-S-i>", lsp.code_action, opts)
      vim.keymap.set("i", "<A-CR>", lsp.code_action, opts)
      -- Format file: format the entire buffer using LSP formatter
      vim.keymap.set("n", "<leader>f", lsp.format, opts)
      -- Format selection: format visual selection and exit visual mode
      vim.keymap.set("v", "<leader>f", function()
        lsp.format()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
      end, opts)
      -- Previous diagnostic: jump to the previous error/warning
      vim.keymap.set("n", "[g", vim.diagnostic.goto_prev, opts)
      -- Next diagnostic: jump to the next error/warning
      vim.keymap.set("n", "]g", vim.diagnostic.goto_next, opts)
      -- Type definition: jump to the type of the symbol under cursor
      vim.keymap.set("n", "<S-b>", lsp.type_definition, opts)
      -- Implementation: jump or peekview if multiple implementations
      local implementation = require("plugins.lsp.implementation").open
      vim.keymap.set("n", "<A-j>", implementation, opts)
      -- Workspace symbols: search symbols across the entire project
      vim.keymap.set("n", "<C-t>", lsp.workspace_symbol, opts)
      -- Document outline: show file symbols in a right-side panel
      vim.keymap.set("n", "<leader>o", handlers.document_outline, opts)
      -- Selection range: progressively expand selection by syntax tree
      vim.keymap.set("n", "<C-s>", lsp.selection_range, opts)
      vim.keymap.set("x", "<C-s>", lsp.selection_range, opts)
      -- Show diagnostics: if current line has diagnostics, open focusable float;
      -- otherwise open all diagnostics in location list
      local function diagnostic_float_or_loclist()
        local _, winid = vim.diagnostic.open_float(nil, { focusable = true, focus = true })
        if not winid then
          vim.diagnostic.setloclist()
        end
      end
      vim.keymap.set("n", "<C-e>", diagnostic_float_or_loclist, opts)
      vim.keymap.set("i", "<C-e>", diagnostic_float_or_loclist, opts)
      -- Incoming call tree: show callers of the symbol under cursor
      vim.keymap.set("n", "<C-A-i>", require("plugins.lsp.call_hierarchy").incoming, opts)
      -- Outgoing call tree: show callees of the symbol under cursor
      vim.keymap.set("n", "<C-A-o>", require("plugins.lsp.call_hierarchy").outgoing, opts)
    end,
  })
end

return M
