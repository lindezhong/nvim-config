-- Buf: shared buffer utilities for LSP modules.
--
-- Provides low-level buffer operations used across peekview, goto,
-- and calltree to avoid duplicating the same bufadd/bufload pattern.

local M = {}

-- Ensure a file is loaded into a buffer.
-- Adds the file to the buffer list if not present, then loads its content
-- into memory (triggers filetype detection and syntax highlighting).
-- Returns existing buffer if already loaded, avoids redundant IO.
---@param filename string absolute file path
---@return integer buf buffer number
function M.ensure_loaded(filename)
  -- bufadd: add to buffer list (returns existing bufnr if already present)
  local buf = vim.fn.bufadd(filename)
  -- bufload: read file content into memory only if not yet loaded
  if vim.fn.bufloaded(buf) == 0 then
    vim.fn.bufload(buf)
  end
  -- bufload doesn't always trigger filetype detection; detect explicitly
  if vim.bo[buf].filetype == "" then
    local ft = vim.filetype.match({ buf = buf, filename = filename })
    if ft then
      vim.bo[buf].filetype = ft
    end
  end
  return buf
end

return M
