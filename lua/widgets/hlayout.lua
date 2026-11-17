-- hlayout.lua
-- Horizontal (side-by-side) layout module for the git plugin.
-- Creates a row of vertically-split windows arranged left-to-right,
-- each with an optional fixed width and an optional logical name for
-- lookup via the shared layout registry.

--- Import the base layout module for creating the underlying layout instance
local layout = require("widgets.layout")
--- Shared size helper (absolute values or percentage strings)
local size = require("widgets.size")

--- Neovim API shorthand for window/buffer operations
local api = vim.api

--- @type table Module table exported by this file
local M = {}

--- Create a horizontal layout with the specified child window definitions.
-- Opens a series of vertical splits from left to right. Each child can
-- specify a fixed width and/or a logical name for registry lookup.
---@param children { width?: integer|string, name?: string }[] List of window specs (width: columns or "25%", and/or name)
---@param registry? table Shared registry from parent layout (nil creates a new root registry)
---@return table self The layout instance populated with created windows and buffers
function M.create(children, registry)
  -- Create the base layout instance, inheriting or initializing the registry
  local self = layout.create(registry)

  -- Save the current window so we can restore focus after creating splits
  local cur_win = api.nvim_get_current_win()
  -- Track windows as they are created for sequential split positioning
  local created_wins = {}

  -- Iterate over each child spec to create a vertical split window
  for i, child in ipairs(children) do
    local win
    if i == 1 then
      -- First window: create a top-left vertical split
      vim.cmd("topleft vsplit")
      win = api.nvim_get_current_win()
    else
      -- Subsequent windows: split to the right of the previous window
      local prev_win = created_wins[#created_wins]
      api.nvim_set_current_win(prev_win)
      vim.cmd("rightbelow vsplit")
      win = api.nvim_get_current_win()
    end

    -- Apply fixed width if specified in the child definition
    -- (number = columns, string like "25%" = percentage of editor width)
    if child.width then
      api.nvim_win_set_width(win, size.resolve(child.width, "width"))
      vim.wo[win].winfixwidth = true  -- Prevent Vim from auto-resizing this window
    end
    -- Create a new scratch buffer and assign it to the window
    local buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(win, buf)

    -- Track the window and buffer in the layout's state
    self.wins[#self.wins + 1] = win
    self.bufs[#self.bufs + 1] = buf
    -- Register the window under its logical name if one was given
    if child.name then
      self:register(child.name, win)
    end
    -- Append to the local tracking list for positioning subsequent splits
    created_wins[#created_wins + 1] = win
  end

  -- Restore the original window focus if it is still valid
  if api.nvim_win_is_valid(cur_win) then
    api.nvim_set_current_win(cur_win)
  end

  return self
end

return M
