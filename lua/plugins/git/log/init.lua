-- Git log module entry point.
-- Provides the public API for opening the git log viewer window.
-- This module delegates to logwindow for the actual UI creation and management.

-- Import the logwindow module that handles window creation and management
local logwindow = require("plugins.git.log.logwindow")

--- @type table Module table for git log operations
local M = {}

--- Options for opening the git log viewer
---@class LogOpenOpts
---@field path string? Optional file path to filter log by
---@field count number? Optional maximum number of commits to display
---@field author string? Optional author name to filter commits by

--- Open the git log viewer window with the given options.
-- Creates a new log window showing commit history, optionally filtered
-- by file path, commit count, or author.
---@param opts LogOpenOpts? Options controlling what commits to display
function M.open(opts)
  -- Default to empty options if none provided
  opts = opts or {}
  -- Delegate to logwindow.open with the filtered options
  logwindow.open({
    path = opts.path,       -- file path filter (nil means all files)
    count = opts.count,     -- max number of commits to show
    author = opts.author,   -- author name filter
  })
end

return M
