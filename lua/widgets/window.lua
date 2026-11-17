-- window.lua
-- Tab-based window container for the git plugin's layout system.
-- Wraps a layout inside a dedicated tab page, providing open/close/rebuild
-- lifecycle methods. The tab isolates the git UI from the user's existing
-- editor windows and restores focus to the previous window on close.

--- Neovim API shorthand for window/buffer operations
local api = vim.api

--- @type table Module table exported by this file
local M = {}

--- Create a new tab-based window container.
-- The container opens a new tab, invokes the provided layout factory function
-- to populate it with windows, then removes the default empty window/buffer
-- that Neovim creates for the new tab.
---@param layout_fn fun(): table A factory function that creates and returns a layout instance
---@return table self The window container with open/close/rebuild methods
function M.create(layout_fn)
  --- @type table The window container instance holding state and methods
  local self = {
    layout = nil,       -- The current layout instance (set after open)
    restore_win = nil,  -- Window handle to restore focus to on close
  }

  --- Open the window container in a new tab page.
  -- Saves the current window for later restoration, creates a new tab,
  -- builds the layout via layout_fn, and cleans up the tab's default
  -- empty window/buffer if the layout did not reuse them.
  function self:open()
    -- Remember which window was active before opening the git UI
    self.restore_win = api.nvim_get_current_win()

    -- Create a new tab page for the git UI
    vim.cmd("tabnew")
    -- Capture the default window and buffer that tabnew creates
    local tab_win = api.nvim_get_current_win()
    local tab_buf = api.nvim_win_get_buf(tab_win)

    -- Invoke the layout factory in a protected call to handle errors gracefully
    local ok, result = pcall(layout_fn)
    if not ok then
      -- Notify the user and abort if the layout could not be created
      vim.notify("layout creation failed: " .. tostring(result), vim.log.levels.ERROR)
      return
    end
    -- Store the successfully created layout
    self.layout = result

    -- Close the default tab window if it was not claimed by the layout
    if api.nvim_win_is_valid(tab_win) and not vim.tbl_contains(self.layout.wins, tab_win) then
      api.nvim_win_close(tab_win, true)
    end
    -- Delete the default tab buffer if it is still an unnamed empty buffer
    if api.nvim_buf_is_valid(tab_buf) and vim.bo[tab_buf].buftype == "" and vim.fn.bufname(tab_buf) == "" then
      api.nvim_buf_delete(tab_buf, { force = true })
    end
  end

  --- Close the window container.
  -- If multiple tabs exist, closes just the current tab. Otherwise destroys
  -- the layout directly. Restores focus to the window that was active before
  -- the container was opened.
  function self:close()
    -- Determine how many tab pages are open
    local tab_count = #api.nvim_list_tabpages()
    if tab_count > 1 then
      -- Multiple tabs: close only the current tab (leaves others intact)
      pcall(vim.cmd, "tabclose")
    else
      -- Single tab: cannot close the tab, so destroy the layout windows directly
      self.layout:destroy()
    end

    -- Restore focus to the window that was active before opening
    if self.restore_win and api.nvim_win_is_valid(self.restore_win) then
      api.nvim_set_current_win(self.restore_win)
    end
  end

  --- Destroy the current layout and create a new one in place.
  -- A temporary window is created to hold the tab alive while the old layout
  -- is destroyed and the new one is built. Protected with pcall so that a
  -- failed layout_fn does not leave the temporary window dangling.
  ---@param new_layout_fn? fun(): table Optional override factory; falls back to the original layout_fn
  function self:rebuild_layout(new_layout_fn)
    -- Destroy all windows/buffers of the current layout
    self.layout:destroy()

    -- Temporary window to keep the tab page alive after destroying all layout windows
    vim.cmd("new")
    local tmp_win = api.nvim_get_current_win()

    -- Attempt to build the new layout using the provided or original factory
    local ok, result = pcall(new_layout_fn or layout_fn)
    if not ok then
      -- Clean up the temporary window on failure
      if api.nvim_win_is_valid(tmp_win) then
        api.nvim_win_close(tmp_win, true)
      end
      -- Notify the user about the rebuild failure
      vim.notify("layout rebuild failed: " .. tostring(result), vim.log.levels.ERROR)
      return
    end
    -- Store the newly created layout
    self.layout = result

    -- Remove the temporary window if the new layout did not reuse it
    if api.nvim_win_is_valid(tmp_win) and not vim.tbl_contains(self.layout.wins, tmp_win) then
      api.nvim_win_close(tmp_win, true)
    end
  end

  return self
end

return M
