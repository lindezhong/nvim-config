-- diffview.lua
-- Provides the core diff viewing logic for displaying file differences.
-- Supports two modes: "vimdiff" (side-by-side diff using Neovim's built-in diff)
-- and "unified" (single-pane unified diff output).
-- Manages scratch buffers for old/new file content and handles cleanup.

--- @module plugins.git.diff.diffview

-- Import the base view module for creating view instances
local view = require("plugins.git.widgets.view")
-- Import the git module for retrieving file contents and diffs
local git = require("plugins.git.git")

-- Alias for the Neovim API namespace
local api = vim.api
--- @type table Module table exported by this file
local M = {}

--- Create a new diffview instance.
-- Initializes a view with diff-specific state fields.
-- @return table A new diffview instance with mode, old_buf, new_buf, and unified_buf fields
function M.create()
  -- Create a base view instance from the core view module
  local self = view.create()
  -- Set the default diff display mode to vimdiff (side-by-side)
  self.mode = "vimdiff"
  -- Buffer handle for the old (reference) version of the file
  self.old_buf = nil
  -- Buffer handle for the new (target) version of the file
  self.new_buf = nil
  -- Buffer handle for the unified diff output
  self.unified_buf = nil
  -- Return the initialized diffview instance
  return self
end

--- Show a side-by-side vimdiff for a file between two refs.
-- Clears any previous diff state, creates buffers for the old and new versions,
-- sets them into the provided windows, and enables Neovim's diff mode.
---@param inst table The diffview instance (created by M.create())
---@param opts { ref1: string?, ref2: string?, path: string, cached: boolean?, win_old: integer, win_new: integer }
---  ref1: git ref for the old version (nil uses index or HEAD depending on cached)
---  ref2: git ref for the new version (nil uses working tree)
---  path: relative file path within the repository
---  cached: if true, compare HEAD vs staged (index)
---  win_old: window ID to display the old version
---  win_new: window ID to display the new version
function M.show_vimdiff(inst, opts)
  -- Clear any existing diff buffers and state from the instance
  M.clear(inst)
  -- Set the mode to vimdiff for this display
  inst.mode = "vimdiff"

  -- Determine the content for the old (left) side of the diff
  local old_lines
  if opts.ref1 then
    -- If an explicit ref is given, use it to retrieve file content
    old_lines = git.file_content(opts.ref1, opts.path)
  elseif opts.cached then
    -- For cached (staged) diffs, the old side is HEAD
    old_lines = git.file_content("HEAD", opts.path)
  else
    -- Otherwise use the index version (empty string means index)
    old_lines = git.file_content("", opts.path) -- index version
  end

  -- Create a scratch buffer for the old (git) version
  inst.old_buf = api.nvim_create_buf(false, true)
  -- Mark buffer as non-file (scratch) so it won't prompt for save
  vim.bo[inst.old_buf].buftype = "nofile"
  -- Wipe the buffer when it becomes hidden
  vim.bo[inst.old_buf].bufhidden = "wipe"
  -- Disable swap file for this scratch buffer
  vim.bo[inst.old_buf].swapfile = false
  if old_lines then
    -- Populate the buffer with the old file content
    api.nvim_buf_set_lines(inst.old_buf, 0, -1, false, old_lines)
  end
  -- Make the old buffer read-only to prevent accidental edits
  vim.bo[inst.old_buf].modifiable = false

  -- Detect the filetype from the file path for syntax highlighting
  local ft = vim.filetype.match({ filename = opts.path }) or ""
  if ft ~= "" then
    -- Apply the detected filetype to enable syntax highlighting
    vim.bo[inst.old_buf].filetype = ft
  end

  -- Determine the content for the new (right) side of the diff
  local new_lines
  if opts.ref2 then
    -- If ref2 is given, retrieve that specific version from git
    new_lines = git.file_content(opts.ref2, opts.path)
    -- Create a scratch buffer for the new version
    inst.new_buf = api.nvim_create_buf(false, true)
    -- Mark as non-file scratch buffer
    vim.bo[inst.new_buf].buftype = "nofile"
    -- Wipe when hidden
    vim.bo[inst.new_buf].bufhidden = "wipe"
    -- Disable swap file
    vim.bo[inst.new_buf].swapfile = false
    if new_lines then
      -- Populate the new buffer with the retrieved content
      api.nvim_buf_set_lines(inst.new_buf, 0, -1, false, new_lines)
    end
    -- Make the new buffer read-only
    vim.bo[inst.new_buf].modifiable = false
    if ft ~= "" then
      -- Apply filetype for syntax highlighting on the new buffer
      vim.bo[inst.new_buf].filetype = ft
    end
  else
    -- No ref2 means compare against the working tree file
    local root = git.root() or ""
    -- Build the absolute path to the working tree file
    local abs_path = root .. "/" .. opts.path
    -- Add the file buffer (reuses existing buffer if already loaded)
    inst.new_buf = vim.fn.bufadd(abs_path)
    -- Temporarily suppress swap file warning messages
    local saved_shm = vim.o.shortmess
    vim.o.shortmess = saved_shm .. "A"
    -- Load the buffer contents from disk
    local ok = pcall(vim.fn.bufload, inst.new_buf)
    -- Restore the original shortmess setting
    vim.o.shortmess = saved_shm
    if not ok then
      -- If buffer loading failed, abort without showing diff
      return
    end
  end

  -- Set buffers into their respective windows and activate diff mode
  if opts.win_old and api.nvim_win_is_valid(opts.win_old) then
    -- Place the old buffer into the old (left) window
    api.nvim_win_set_buf(opts.win_old, inst.old_buf)
    -- Enable Neovim's diff mode in the old window
    api.nvim_win_call(opts.win_old, function()
      vim.cmd("diffthis")
    end)
    -- Hide fold column in the diff window for cleaner display
    vim.wo[opts.win_old].foldcolumn = "0"
    -- Hide sign column in the diff window
    vim.wo[opts.win_old].signcolumn = "no"
  end
  if opts.win_new and api.nvim_win_is_valid(opts.win_new) then
    -- Place the new buffer into the new (right) window
    api.nvim_win_set_buf(opts.win_new, inst.new_buf)
    -- Enable Neovim's diff mode in the new window
    api.nvim_win_call(opts.win_new, function()
      vim.cmd("diffthis")
    end)
    -- Hide fold column in the diff window for cleaner display
    vim.wo[opts.win_new].foldcolumn = "0"
    -- Hide sign column in the diff window
    vim.wo[opts.win_new].signcolumn = "no"
  end

  -- Position the cursor at the first change in the diff
  local target_win = opts.win_new or opts.win_old
  if target_win and api.nvim_win_is_valid(target_win) then
    local old_win = opts.win_old
    -- Check if the old window buffer is empty (new file scenario)
    local old_is_empty = old_win and api.nvim_win_is_valid(old_win)
      and api.nvim_buf_line_count(api.nvim_win_get_buf(old_win)) <= 1

    -- Disable scrollbind temporarily to position windows independently
    if old_win and api.nvim_win_is_valid(old_win) then
      vim.wo[old_win].scrollbind = false
    end
    vim.wo[target_win].scrollbind = false

    -- Jump to the first change in the new window: go to top, next change, back to first change
    vim.fn.win_execute(target_win, "norm! gg]c[c0")
    -- Center the view around the first change
    vim.fn.win_execute(target_win, "norm! ztzz")

    -- Position old window at the very top of the file
    if old_win and api.nvim_win_is_valid(old_win) then
      vim.fn.win_execute(old_win, "norm! ggzt")
    end

    -- Re-enable scrollbind only if the old buffer has content (not a new file)
    if old_win and api.nvim_win_is_valid(old_win) and not old_is_empty then
      vim.wo[old_win].scrollbind = true
    end
    -- Sync scrollbind on target window based on whether old has content
    vim.wo[target_win].scrollbind = not old_is_empty
  end
end

--- Show a unified diff for a file between two refs.
-- Clears previous state, generates a unified diff output, and displays it
-- in a single buffer with "diff" filetype for syntax highlighting.
---@param inst table The diffview instance (created by M.create())
---@param opts { ref1: string?, ref2: string?, path: string, cached: boolean?, win: integer }
---  ref1: git ref for the old version
---  ref2: git ref for the new version
---  path: relative file path within the repository
---  cached: if true, show staged changes
---  win: window ID to display the unified diff
function M.show_unified(inst, opts)
  -- Clear any existing diff buffers and state from the instance
  M.clear(inst)
  -- Set the mode to unified for this display
  inst.mode = "unified"

  -- Generate the unified diff output lines via git
  local diff_lines = git.diff_content({
    ref1 = opts.ref1,
    ref2 = opts.ref2,
    cached = opts.cached,
    path = opts.path,
  })

  -- Create a scratch buffer for the unified diff output
  inst.unified_buf = api.nvim_create_buf(false, true)
  -- Mark as non-file scratch buffer
  vim.bo[inst.unified_buf].buftype = "nofile"
  -- Wipe when hidden
  vim.bo[inst.unified_buf].bufhidden = "wipe"
  -- Disable swap file
  vim.bo[inst.unified_buf].swapfile = false
  -- Populate the buffer with the diff lines
  api.nvim_buf_set_lines(inst.unified_buf, 0, -1, false, diff_lines)
  -- Make the buffer read-only
  vim.bo[inst.unified_buf].modifiable = false
  -- Set filetype to "diff" for proper syntax highlighting
  vim.bo[inst.unified_buf].filetype = "diff"

  -- Display the unified diff buffer in the target window
  if opts.win and api.nvim_win_is_valid(opts.win) then
    api.nvim_win_set_buf(opts.win, inst.unified_buf)
  end
end

--- Clear all diff buffers and reset the instance state.
-- Turns off diff mode in any windows displaying our buffers, replaces them
-- with empty buffers, then deletes the diff buffers.
---@param inst table The diffview instance to clear
function M.clear(inst)
  -- Iterate over all windows to find and clean up ones showing our buffers
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) then
      -- Get the buffer currently displayed in this window
      local buf = api.nvim_win_get_buf(win)
      -- Check if this window is showing one of our diff buffers
      if buf == inst.old_buf or buf == inst.new_buf or buf == inst.unified_buf then
        -- Turn off diff mode in this window
        api.nvim_win_call(win, function()
          vim.cmd("diffoff")
        end)
        -- Replace with an empty buffer so deleting our buffer won't close the window
        local empty = api.nvim_create_buf(false, true)
        api.nvim_win_set_buf(win, empty)
      end
    end
  end

  -- Delete the old buffer if it still exists
  if inst.old_buf and api.nvim_buf_is_valid(inst.old_buf) then
    api.nvim_buf_delete(inst.old_buf, { force = true })
  end
  -- Delete the new buffer only if it's a scratch buffer (not a real file buffer)
  if inst.new_buf and api.nvim_buf_is_valid(inst.new_buf) then
    -- Only delete scratch buffers, not real file buffers from the working tree
    if vim.bo[inst.new_buf].buftype == "nofile" then
      api.nvim_buf_delete(inst.new_buf, { force = true })
    end
  end
  -- Delete the unified diff buffer if it still exists
  if inst.unified_buf and api.nvim_buf_is_valid(inst.unified_buf) then
    api.nvim_buf_delete(inst.unified_buf, { force = true })
  end
  -- Reset all buffer handles to nil
  inst.old_buf = nil
  inst.new_buf = nil
  inst.unified_buf = nil
end

return M
