-- Git log detail view.
-- Creates and manages a scratch buffer used to display the detailed content
-- of a selected git commit (e.g., full diff output from `git show`).
-- The buffer is non-modifiable by default and uses the "git" filetype for syntax highlighting.

-- Import the base view module for creating view instances
local view = require("plugins.git.widgets.view")

-- Shortcut reference to the Neovim API
local api = vim.api

--- @type table Module table for logview operations
local M = {}

--- Create a new log view instance.
-- Allocates a scratch buffer configured for displaying read-only git content.
-- The buffer is unlisted, non-file-backed, and will be wiped when hidden.
---@return table self The view instance with a `buf` field referencing the created buffer
function M.create()
  -- Create a base view instance (provides common view infrastructure)
  local self = view.create()
  -- Create an unlisted scratch buffer (not associated with any file)
  self.buf = api.nvim_create_buf(false, true)

  -- Set buffer options for scratch/read-only behavior
  vim.bo[self.buf].buftype = "nofile"      -- Buffer is not associated with a file
  vim.bo[self.buf].bufhidden = "wipe"      -- Wipe buffer when it becomes hidden
  vim.bo[self.buf].swapfile = false         -- Disable swap file for this buffer
  vim.bo[self.buf].filetype = "git"         -- Set filetype to "git" for syntax highlighting

  return self
end

--- Display content lines in the log view buffer.
-- Replaces all lines in the buffer with the provided content.
-- Temporarily makes the buffer modifiable to set lines, then locks it again.
---@param inst table The log view instance (must have a valid `buf` field)
---@param content_lines string[] Array of strings to display, one per line
function M.show(inst, content_lines)
  -- Guard: do nothing if the buffer is invalid or was already wiped
  if not inst.buf or not api.nvim_buf_is_valid(inst.buf) then
    return
  end
  -- Temporarily allow modifications to update the buffer content
  vim.bo[inst.buf].modifiable = true
  -- Replace all lines in the buffer with the new content
  api.nvim_buf_set_lines(inst.buf, 0, -1, false, content_lines)
  -- Lock the buffer again to prevent user edits
  vim.bo[inst.buf].modifiable = false
end

return M
