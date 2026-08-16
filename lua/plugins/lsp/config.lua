-- LSP diagnostics display configuration
--
-- Controls how diagnostic messages (errors, warnings, hints, info) are
-- presented in the editor:
-- 1. Signs: show E/W/I/H letters in the sign column (merged with line numbers)
-- 2. Virtual text: disabled (no inline text after code lines)
-- 3. Float: auto-show diagnostic details when cursor holds on a diagnostic line
--
-- Diagnostics data comes from LSP servers via textDocument/publishDiagnostics.
-- Only files with an attached LSP client produce diagnostics.

local M = {}

--- Configure diagnostic display settings and auto-float behavior
function M.setup()
  vim.diagnostic.config({
    -- Disable inline virtual text after code lines (too noisy)
    virtual_text = false,
    -- Sign column letters for each severity level (terminal-friendly, no icons)
    signs = {
      text = {
        [vim.diagnostic.severity.ERROR] = "E",
        [vim.diagnostic.severity.WARN] = "W",
        [vim.diagnostic.severity.INFO] = "I",
        [vim.diagnostic.severity.HINT] = "H",
      },
    },
    -- Float window options: include the diagnostic source (e.g. "lua_ls", "vtsls")
    float = { source = true },
  })

  -- Auto-show diagnostic float when cursor holds on a line with issues
  -- Triggers after `updatetime` ms (300ms, configured in init.lua)
  vim.api.nvim_create_autocmd("CursorHold", {
    callback = function()
      -- Open a non-focusable float so it doesn't interfere with editing
      vim.diagnostic.open_float(nil, { focusable = false })
    end,
  })
end

return M
