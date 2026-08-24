-- vlayout.lua
-- Vertical (stacked) layout module for the git plugin.
-- Creates a column of horizontally-split windows arranged top-to-bottom,
-- each with an optional fixed height and an optional logical name for
-- lookup via the shared layout registry.

--- Import the base layout module for creating the underlying layout instance
local layout = require("plugins.git.widgets.layout")

--- Neovim API shorthand for window/buffer operations
local api = vim.api

--- @type table Module table exported by this file
local M = {}

--- Create a vertical layout with the specified child window definitions.
-- Opens a series of horizontal splits from top to bottom. Each child can
-- specify a fixed height and/or a logical name for registry lookup.
---@param children { height?: integer, name?: string }[] List of window specs (height and/or name)
---@param registry? table Shared registry from parent layout (nil creates a new root registry)
---@return table self The layout instance populated with created windows and buffers
function M.create(children, registry)
  -- Create the base layout instance, inheriting or initializing the registry
  local self = layout.create(registry)

  -- Save the current window so we can restore focus after creating splits
  local cur_win = api.nvim_get_current_win()
  -- Track windows as they are created for sequential split positioning
  local created_wins = {}

  -- Iterate over each child spec to create a horizontal split window
  for i, child in ipairs(children) do
    local win
    if i == 1 then
      -- First window: create a top-left horizontal split
      vim.cmd("topleft split")
      win = api.nvim_get_current_win()
    else
      -- Subsequent windows: split below the previous window
      local prev_win = created_wins[#created_wins]
      api.nvim_set_current_win(prev_win)
      vim.cmd("rightbelow split")
      win = api.nvim_get_current_win()
    end

    -- Apply fixed height if specified in the child definition
    if child.height then
      api.nvim_win_set_height(win, child.height)
      vim.wo[win].winfixheight = true  -- Prevent Vim from auto-resizing this window
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
