-- Git log window module.
-- Manages the full log viewer UI consisting of a horizontally split layout:
--   Left pane: a scrollable list of commits (listview widget)
--   Right pane: detailed commit content (logview buffer showing `git show` output)
-- Supports debounced cursor-follow to load commit details, and selecting a commit
-- opens its diff in a separate diff window.

-- Import the base window module for window lifecycle management
local window = require("widgets.window")
-- Import horizontal layout utility for splitting the window
local hlayout = require("widgets.hlayout")
-- Import the listview widget for rendering a selectable list of items
local listview = require("widgets.listview")
-- Import the logview module for the detail pane buffer
local logview = require("plugins.git.log.logview")
-- Import the diff window module for viewing commit diffs
local diffwindow = require("plugins.git.diff.diffwindow")
-- Import git operations module for fetching log/show/commit data
local git = require("plugins.git.git")

-- Shortcut reference to the Neovim API
local api = vim.api

--- @type table Module table for log window operations
local M = {}

--- Singleton state tracking the currently open log window.
-- nil when no log window is open; holds references to all UI components when open.
---@type table|nil
local state = nil

--- Options for opening the log window
---@class LogWindowOpts
---@field path string? Optional file path to filter log by
---@field count number? Optional maximum number of commits to display
---@field author string? Optional author name to filter commits by

--- Open the git log window.
-- If a log window is already open, it will be closed first.
-- Creates a horizontal layout with a commit list on the left and commit details on the right.
-- Wires up cursor movement (debounced) to show commit details, and Enter/select to open diff.
---@param opts LogWindowOpts? Options controlling what commits to display
function M.open(opts)
  -- Close any existing log window before opening a new one
  if state then
    M.close()
  end

  -- Merge defaults into options
  opts = opts or {}
  -- Default to showing 200 commits if no count specified
  local count = opts.count or 200

  -- Create a window with a horizontal layout: left pane (50 cols) for list, right pane for detail
  local win = window.create(function()
    return hlayout.create({ { width = 50, name = "list" }, { name = "detail" } })
  end)
  -- Open the window (renders the layout into actual Neovim windows)
  win:open()
  -- Get the layout object to access named panes
  local layout = win.layout

  -- Create a listview widget with an async items provider and a formatting function
  local list = listview.create({
    -- Async item provider: fetches full log data from git and passes commits to callback
    items = function(cb)
      local commits = git.log_full({
        path = opts.path,       -- optional file path filter
        count = count,          -- max number of commits to fetch
        author = opts.author,   -- optional author filter
      })
      -- Pass the fetched commits to the listview callback
      cb(commits)
    end,
    -- Format a commit element into a display-friendly list item structure
    get_list_item = function(element)
      -- Indent the subject line with spaces
      local msg = "    " .. element.subject
      -- If there is a body, append it with each line indented
      if element.body ~= "" then
        msg = msg .. "\n\n" .. element.body:gsub("([^\n]+)", "    %1")
      end
      return {
        -- Icon shows the abbreviated commit hash with highlight
        icon = { text = "commit " .. element.hash, hlGroup = "GitLogHash" },
        -- Label shows author and date info
        label = "Author: " .. element.author .. "\nDate:   " .. element.date,
        -- Description shows the formatted commit message
        description = "\n" .. msg .. "\n",
      }
    end,
  })

  -- Create a logview instance for the detail pane (right side)
  local log = logview.create()

  -- Get the window IDs for the left (list) and right (detail) panes
  local list_win = layout:get("list")
  local log_win = layout:get("detail")

  -- Configure the list pane window options
  if list_win and api.nvim_win_is_valid(list_win) then
    -- Set the listview buffer into the list pane window
    api.nvim_win_set_buf(list_win, list.buf)
    -- Disable line numbers for a cleaner list appearance
    vim.wo[list_win].number = false
    -- Disable relative line numbers
    vim.wo[list_win].relativenumber = false
    -- Hide the sign column
    vim.wo[list_win].signcolumn = "no"
    -- Hide the fold column
    vim.wo[list_win].foldcolumn = "0"
    -- Disable line wrapping so long subjects don't wrap
    vim.wo[list_win].wrap = false
    -- Enable cursorline to highlight the selected commit
    vim.wo[list_win].cursorline = true
  end

  -- Configure the detail pane window options
  if log_win and api.nvim_win_is_valid(log_win) then
    -- Set the logview buffer into the detail pane window
    api.nvim_win_set_buf(log_win, log.buf)
    -- Disable line wrapping for diff content
    vim.wo[log_win].wrap = false
  end

  -- Store all state for the currently open log window
  state = {
    win = win,                      -- the base window instance
    list = list,                    -- the listview widget instance
    log = log,                      -- the logview instance
    opts = opts,                    -- the options used to open this window
    show_timer = vim.uv.new_timer(), -- debounce timer for showing commit details
  }

  -- Wire the cursor event: when cursor moves in the list, show commit details (debounced)
  local show_timer = state.show_timer
  list:on("cursor", function(element)
    -- Stop any previously scheduled detail load
    show_timer:stop()
    -- Start a 50ms debounce timer before loading commit details
    show_timer:start(50, 0, vim.schedule_wrap(function()
      -- Guard against race condition if window was closed during timer
      if not state then return end
      -- Fetch the full commit content (diff) for the selected commit
      local content = git.show(element.hash)
      -- Display the commit content in the logview buffer
      logview.show(log, content)
    end))
  end)

  -- Wire the select event: when user presses Enter on a commit, open its diff
  list:on("select", function(element)
    -- Get the list of files changed in this commit
    local files = git.commit_files(element.hash)
    -- Close the log window since we're switching to diff view
    M.close()
    -- Open a diff window comparing parent commit to the selected commit
    diffwindow.open({
      files = files,                      -- list of changed files
      ref1 = element.hash .. "^",         -- parent commit (ref^)
      ref2 = element.hash,                -- the selected commit
      mode = "vimdiff",                   -- use vimdiff split mode
    })
  end)

  -- Set up keymap: press 'q' in the list buffer to close the log window
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = list.buf, silent = true })

  -- Focus the list pane so the user can immediately navigate commits
  if list_win and api.nvim_win_is_valid(list_win) then
    api.nvim_set_current_win(list_win)
  end
end

--- Close the git log window and clean up all resources.
-- Stops the debounce timer, closes list and log views, and closes the base window.
-- Safe to call when already closed (no-op if state is nil).
function M.close()
  -- Guard: do nothing if no log window is currently open
  if not state then
    return
  end

  -- Capture state and clear the global reference immediately to prevent re-entry
  local s = state
  state = nil

  -- Stop and release the debounce timer
  if s.show_timer then
    s.show_timer:stop()   -- stop any pending callback
    s.show_timer:close()  -- release the libuv timer handle
  end
  -- Close the listview widget (pcall to handle already-closed gracefully)
  pcall(function() s.list:close() end)
  -- Close the logview instance (pcall to handle already-closed gracefully)
  pcall(function() s.log:close() end)
  -- Close the base window (removes all Neovim windows/splits)
  s.win:close()
end

--- Check whether the git log window is currently open.
---@return boolean True if the log window is open, false otherwise
function M.is_open()
  return state ~= nil
end

return M
