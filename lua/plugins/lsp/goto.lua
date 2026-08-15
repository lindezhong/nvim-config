-- Goto: utility for jumping to a code location without flicker.
--
-- Provides a single jump_to function used by references, definition,
-- and any other LSP feature that needs to navigate to a file position.
-- Uses nvim_win_set_buf instead of vim.cmd("edit") to avoid screen flicker.

-- A code location that can be jumped to.
---@class GotoLocation
---@field filename string absolute file path
---@field lnum integer line number (1-indexed)
---@field col integer column number (1-indexed)

local buf_utils = require("plugins.lsp.buf")

local M = {}

-- Jump to a code location in the specified window.
-- Switches buffer only when the target file differs from the current one,
-- avoiding unnecessary buffer switches for same-file jumps.
---@param win integer target window to jump in
---@param loc GotoLocation location to jump to
function M.jump_to(win, loc)
  -- Window may have been closed by user
  if not vim.api.nvim_win_is_valid(win) then return end
  -- Focus the target window
  vim.api.nvim_set_current_win(win)
  -- Load target file into buffer
  local buf = buf_utils.ensure_loaded(loc.filename)
  -- Only switch buffer when jumping to a different file (avoids flicker)
  if buf ~= vim.api.nvim_win_get_buf(win) then
    vim.api.nvim_win_set_buf(win, buf)
  end
  -- Set cursor position (col is 1-indexed, nvim expects 0-indexed col)
  vim.api.nvim_win_set_cursor(win, { loc.lnum, loc.col - 1 })
end

return M
