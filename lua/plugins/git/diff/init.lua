-- init.lua (plugins.git.diff)
-- Entry point for the git diff module.
-- Provides high-level functions to open diff views for arbitrary git refs
-- or for the current working tree status. Delegates the actual UI rendering
-- to the diffwindow module.

--- @module plugins.git.diff

-- Import the git module for querying diffs and status
local git = require("plugins.git.git")
-- Import the diffwindow module that manages the full diff UI
local diffwindow = require("plugins.git.diff.diffwindow")

--- @type table Module table exported by this file
local M = {}

--- @class DiffOpenOpts
--- @field ref1 string? Git ref for the old (left) side of the diff
--- @field ref2 string? Git ref for the new (right) side of the diff
--- @field cached boolean? If true, show staged (index) changes vs HEAD
--- @field mode "vimdiff"|"unified" Display mode (side-by-side or unified patch)
--- @field path string? Optional path filter to limit diff to specific file/directory

--- Open a diff view comparing two git refs or the working tree.
-- Queries git for the list of changed files matching the given options,
-- then opens the diff window to display them.
---@param opts DiffOpenOpts? Options controlling what to diff (nil uses defaults)
function M.open(opts)
  -- Default to empty options if none provided
  opts = opts or {}
  -- Query git for the list of files that differ between the given refs
  local files = git.diff_files({
    ref1 = opts.ref1,
    ref2 = opts.ref2,
    cached = opts.cached,
    path = opts.path,
  })
  -- If no files differ, notify the user and exit early
  if #files == 0 then
    vim.notify("No differences found", vim.log.levels.INFO)
    return
  end
  -- Open the diff window with the found files and options
  diffwindow.open({
    files = files,
    ref1 = opts.ref1,
    ref2 = opts.ref2,
    cached = opts.cached,
    mode = opts.mode or "vimdiff",
    path = opts.path,
  })
end

--- @class StatusOpenOpts
--- @field mode "vimdiff"|"unified" Display mode for the status view

--- Open a diff view showing the current working tree status.
-- Shows all modified, added, deleted, and untracked files compared to the index.
-- Provides a refresh function so the file list updates when "R" is pressed.
---@param opts StatusOpenOpts? Options controlling the display mode (nil uses defaults)
function M.status(opts)
  -- Default to empty options if none provided
  opts = opts or {}
  -- Query git for the current working tree status (changed files)
  local files = git.status()
  -- If there are no changes, notify the user and exit early
  if #files == 0 then
    vim.notify("Working tree clean", vim.log.levels.INFO)
    return
  end
  -- Open the diff window with the status files
  diffwindow.open({
    files = files,
    ref1 = nil,       -- No specific old ref (uses index)
    ref2 = nil,       -- No specific new ref (uses working tree)
    cached = false,   -- Not showing cached/staged changes
    mode = opts.mode or "vimdiff",
    -- Provide a refresh function that re-queries git status
    refresh_fn = function()
      return git.status()
    end,
  })
end

return M
