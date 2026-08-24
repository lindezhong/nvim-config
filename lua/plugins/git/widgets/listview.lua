-- List view widget for displaying flat lists of items in a Neovim buffer.
-- Supports multi-line items with icons, labels, and descriptions, each with
-- optional highlight groups. Provides infinite scrolling via load_more callback.

-- Import the base view module that provides event emitting and buffer management
local view = require("plugins.git.widgets.view")

-- Alias for the Neovim API namespace
local api = vim.api

--- @type table Module table exported by this file
local M = {}

--- Namespace for extmark highlights used by the list view
local ns = api.nvim_create_namespace("git_list")

---@class ListItem
---@field label string The main text displayed for this list entry
---@field label_hl? string Optional highlight group for the label text
---@field icon? TreeItemIcon Optional icon displayed on its own line above the label
---@field description? string Optional description text displayed below the label
---@field description_hl? string Optional highlight group for the description text

---@class ListViewKeys
---@field select? string Key to select/activate an item (default: "<CR>")

---@class ListViewOpts
---@field items any[] | fun(callback: fun(items: any[])) Initial list items, or async function that delivers them via callback
---@field get_list_item fun(element: any): ListItem Function to convert a raw element into a displayable ListItem
---@field has_more? fun(): boolean Optional function returning true if more items can be loaded
---@field load_more? fun(callback: fun(items: any[])) Optional async function to load the next batch of items
---@field keys? ListViewKeys Custom key mappings

--- Creates a new list view widget.
--- Returns a view object with a buffer (.buf) ready to be displayed in a window.
--- Emits events: "select" (element), "cursor" (element).
---@param opts ListViewOpts Configuration options for the list view
---@return table self The list view instance with .buf and :refresh() methods
function M.create(opts)
  -- Create the base view which provides event emitting via self:emit()
  local self = view.create()

  -- Merge user-provided key bindings with defaults
  local keys = vim.tbl_extend("keep", opts.keys or {}, {
    select = "<CR>",
  })

  -- Array holding all currently loaded item elements
  local items = {}

  -- Flag to prevent concurrent load_more requests
  local loading = false

  -- Mapping from buffer line number (1-based) to item index in the items array
  local line_to_item = {}

  --- Renders all items into the buffer with appropriate highlights.
  --- Each item can span multiple lines (icon line, label line(s), description line(s)).
  local function render()
    -- Guard: do nothing if the buffer has been wiped or is invalid
    if not self.buf or not api.nvim_buf_is_valid(self.buf) then
      return
    end

    -- Accumulator for all text lines to write into the buffer
    local buf_lines = {}
    -- Reset the line-to-item index mapping
    line_to_item = {}
    -- Accumulator for highlight metadata to apply after writing lines
    local highlights = {}

    -- Build text lines and highlight records for each item
    for idx, element in ipairs(items) do
      -- Convert the raw element to a displayable ListItem
      local item = opts.get_list_item(element)
      -- Text accumulator for this item (may contain newlines for multi-line items)
      local text = ""
      -- Track the byte length of the icon for highlighting purposes
      local icon_len = 0

      -- Add icon text as the first line if present
      if item.icon then
        text = item.icon.text
        icon_len = #item.icon.text
      end

      -- Add label text on a new line (wrapped in parens if it has a highlight group)
      if item.label ~= "" then
        -- Separate from icon line with a newline if icon was added
        if text ~= "" then
          text = text .. "\n"
        end
        if item.label_hl then
          -- Wrap in parentheses when label has a highlight group (visual distinction)
          text = text .. "(" .. item.label .. ")"
        else
          -- Plain label text without wrapping
          text = text .. item.label
        end
      end

      -- Add description text on a new line if present
      if item.description and item.description ~= "" then
        -- Separate from previous content with a newline
        if text ~= "" then
          text = text .. "\n"
        end
        text = text .. item.description
      end

      -- Split the composed text into individual lines for the buffer
      local item_lines = vim.split(text, "\n", { plain = true })
      -- Record the starting row in the buffer for highlight calculations
      local start_row = #buf_lines

      -- Add each line to the buffer and map it back to this item's index
      for _, l in ipairs(item_lines) do
        buf_lines[#buf_lines + 1] = l
        -- Map this line number to the item index for cursor lookups
        line_to_item[#buf_lines] = idx
      end

      -- Record highlight metadata for post-render application
      highlights[#highlights + 1] = {
        item = item,
        start_row = start_row,
        icon_len = icon_len,
        lines = item_lines,
      }
    end

    -- Write all lines into the buffer (temporarily enable modifiable)
    vim.bo[self.buf].modifiable = true
    api.nvim_buf_set_lines(self.buf, 0, -1, false, buf_lines)
    vim.bo[self.buf].modifiable = false

    -- Clear all existing highlight extmarks in this namespace
    api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)

    -- Apply syntax highlights for each item's components
    for _, h in ipairs(highlights) do
      local item = h.item

      -- Apply icon highlight to the icon portion on the first line
      if item.icon and item.icon.hlGroup and item.icon.hlGroup ~= "" and h.icon_len > 0 then
        api.nvim_buf_set_extmark(self.buf, ns, h.start_row, 0, {
          end_col = h.icon_len,
          hl_group = item.icon.hlGroup,
        })
      end

      -- Apply label highlight to label lines (offset by 1 row if icon is present)
      if item.label_hl and item.label_hl ~= "" and item.label ~= "" then
        -- Label starts on the row after the icon (if icon exists) or at start_row
        local label_start_row = h.start_row + (item.icon and 1 or 0)
        -- Split label in case it spans multiple lines
        local label_lines = vim.split(item.label, "\n", { plain = true })
        for i = 1, #label_lines do
          local row = label_start_row + i - 1
          -- Guard against out-of-bounds access
          if row < #buf_lines then
            api.nvim_buf_set_extmark(self.buf, ns, row, 0, {
              end_col = #buf_lines[row + 1],
              hl_group = item.label_hl,
            })
          end
        end
      end

      -- Apply description highlight to description lines
      if item.description and item.description_hl and item.description ~= "" then
        -- Calculate the row offset where description starts
        local desc_offset = (item.icon and 1 or 0)
        if item.label ~= "" then
          -- Add the number of lines the label occupies
          desc_offset = desc_offset + #vim.split(item.label, "\n", { plain = true })
        end
        local desc_start_row = h.start_row + desc_offset
        -- Split description in case it spans multiple lines
        local desc_lines = vim.split(item.description, "\n", { plain = true })
        for i = 1, #desc_lines do
          local row = desc_start_row + i - 1
          -- Guard against out-of-bounds access
          if row < #buf_lines then
            api.nvim_buf_set_extmark(self.buf, ns, row, 0, {
              end_col = #buf_lines[row + 1],
              hl_group = item.description_hl,
            })
          end
        end
      end
    end
  end

  --- Loads list items either synchronously (from a table) or asynchronously (via callback).
  ---@param callback fun(items: any[]) Function to call with the loaded items
  local function load_items(callback)
    if type(opts.items) == "function" then
      -- Async mode: call the items function with our callback
      opts.items(callback)
    else
      -- Sync mode: directly pass the items table to the callback
      callback(opts.items)
    end
  end

  --- Attempts to load more items when the user scrolls near the bottom.
  --- Guards against concurrent loads and checks if more data is available.
  local function try_load_more()
    -- Prevent concurrent load requests
    if loading then
      return
    end
    -- Do nothing if pagination callbacks are not provided
    if not opts.has_more or not opts.load_more then
      return
    end
    -- Check if there are actually more items to load
    if not opts.has_more() then
      return
    end
    -- Set loading flag to prevent re-entrant calls
    loading = true
    -- Request the next batch of items
    opts.load_more(function(new_items)
      -- Clear loading flag now that we have results
      loading = false
      -- Append new items to the existing list
      for _, item in ipairs(new_items) do
        items[#items + 1] = item
      end
      -- Re-render with the expanded item list
      render()
    end)
  end

  -- Create a scratch buffer for the list view (unlisted, scratch)
  self.buf = api.nvim_create_buf(false, true)
  -- Configure buffer options for a non-file, disposable buffer
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].filetype = "git_list"

  -- Set up the "select" keymap to emit a "select" event for the item under cursor
  vim.keymap.set("n", keys.select, function()
    -- Get the current cursor line (1-based)
    local line = api.nvim_win_get_cursor(0)[1]
    -- Look up which item index this line belongs to
    local idx = line_to_item[line]
    if idx then
      -- Emit the "select" event so consumers can react to item activation
      self:emit("select", items[idx])
    end
  end, { buffer = self.buf, silent = true })

  -- Track the previously highlighted item index to avoid redundant cursor events
  local prev_idx = nil

  -- Set up a CursorMoved autocmd for cursor tracking and infinite scroll
  api.nvim_create_autocmd("CursorMoved", {
    buffer = self.buf,
    callback = function()
      -- Get current cursor line (1-based)
      local line = api.nvim_win_get_cursor(0)[1]
      -- Look up which item the cursor is on
      local idx = line_to_item[line]
      -- Emit cursor event only when the item changes
      if idx and idx ~= prev_idx then
        prev_idx = idx
        -- Emit cursor event so consumers can show previews, details, etc.
        self:emit("cursor", items[idx])
      end
      -- Trigger infinite scroll when cursor is within 3 lines of the bottom
      local total_lines = api.nvim_buf_line_count(self.buf)
      if total_lines > 0 and line >= total_lines - 3 then
        try_load_more()
      end
    end,
  })

  --- Refreshes the list view by reloading all items from the data source.
  function self:refresh()
    -- Clear the current items
    items = {}
    -- Reload from the original data source
    load_items(function(new_items)
      items = new_items
      -- Re-render with the fresh data
      render()
    end)
  end

  -- Perform the initial load of list items
  load_items(function(new_items)
    -- Store the loaded items
    items = new_items
    -- Render the initial list content
    render()
  end)

  return self
end

return M
