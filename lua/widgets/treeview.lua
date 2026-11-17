-- Tree view widget for displaying hierarchical data in a Neovim buffer.
-- Provides collapsible tree nodes with icons, highlights, and keyboard navigation.
-- Used by the git plugin to present file trees and other nested structures.

-- Import the base view module that provides event emitting and buffer management
local view = require("widgets.view")

-- Alias for the Neovim API namespace
local api = vim.api

--- @type table Module table exported by this file
local M = {}

--- Namespace for extmark highlights used by the tree view
local ns = api.nvim_create_namespace("git_tree")

---@class TreeItemIcon
---@field text string The icon character(s) to display
---@field hlGroup string The highlight group to apply to the icon

---@class TreeItem
---@field label string The display text for this tree node
---@field collapsible boolean Whether this node can be expanded/collapsed (i.e., it has children)
---@field icon? TreeItemIcon Optional icon displayed before the label
---@field label_hl? string Optional highlight group for the label text
---@field description? string Optional description text displayed after the label in parentheses
---@field description_hl? string Optional highlight group for the description text

---@class TreeViewIcons
---@field collapsed? string Icon shown for collapsed nodes (default: "▸")
---@field expanded? string Icon shown for expanded nodes (default: "▾")
---@field leaf? string Icon shown for leaf nodes (default: " ")

---@class TreeViewKeys
---@field toggle? string Key to toggle expand/collapse (default: "<Tab>")
---@field select? string Key to select/activate a node (default: "<CR>")

---@class GitTreeViewOpts
---@field items any[] | fun(callback: fun(items: any[])) Tree root items, or async function that delivers them via callback
---@field get_tree_item fun(element: any): TreeItem Function to convert a raw element into a displayable TreeItem
---@field expand_level? integer How many levels to auto-expand on initial load (default: 0)
---@field icons? TreeViewIcons Custom icons for tree indicators
---@field keys? TreeViewKeys Custom key mappings
---@field current? any Element to place the cursor on after initial load

--- Creates a new tree view widget.
--- Returns a view object with a buffer (.buf) ready to be displayed in a window.
--- Emits events: "select" (element), "toggle" (element), "cursor" (element).
---@param opts GitTreeViewOpts Configuration options for the tree view
---@return table self The tree view instance with .buf, :refresh(), :toggle() methods
function M.create(opts)
  -- Create the base view which provides event emitting via self:emit()
  local self = view.create()

  -- Merge user-provided icons with defaults, keeping user values if present
  local icons = vim.tbl_extend("keep", opts.icons or {}, {
    collapsed = "▸",
    expanded = "▾",
    leaf = " ",
  })

  -- Merge user-provided key bindings with defaults
  local keys = vim.tbl_extend("keep", opts.keys or {}, {
    toggle = "<Tab>",
    select = "<CR>",
  })

  -- Number of levels to auto-expand on load (0 means all collapsed)
  local expand_level = opts.expand_level or 0

  -- Array mapping buffer line index to {element, depth} for cursor lookups
  local visible_nodes = {}

  -- Table mapping element references to their expand/collapse state
  local node_states = {}

  --- Retrieves or initializes the expand/collapse state for a given element.
  ---@param element any The tree element to look up
  ---@return table state Table with an `expanded` boolean field
  local function get_state(element)
    -- Initialize state lazily on first access, defaulting to collapsed
    if not node_states[element] then
      node_states[element] = { expanded = false }
    end
    return node_states[element]
  end

  --- Renders the tree into the buffer by walking visible nodes and applying highlights.
  --- Clears and rewrites the entire buffer content.
  local function render()
    -- Guard: do nothing if the buffer has been wiped or is invalid
    if not self.buf or not api.nvim_buf_is_valid(self.buf) then
      return
    end

    -- Accumulator for the text lines to write into the buffer
    local lines = {}
    -- Reset the visible nodes mapping for this render cycle
    visible_nodes = {}

    --- Recursively walks the tree elements and builds display lines.
    ---@param elements any[] List of elements at the current depth
    ---@param depth integer Current indentation depth (0-based)
    local function walk(elements, depth)
      for _, element in ipairs(elements) do
        -- Convert the raw element to a displayable TreeItem
        local item = opts.get_tree_item(element)
        -- Get the expand/collapse state for this element
        local state = get_state(element)
        -- Build indentation string (2 spaces per depth level)
        local indent = string.rep("  ", depth)

        -- Determine the tree structure indicator icon based on node type and state
        local tree_icon
        if not item.collapsible then
          -- Leaf node: use leaf icon (typically a space for alignment)
          tree_icon = icons.leaf
        elseif state.expanded then
          -- Expanded collapsible node: use expanded arrow
          tree_icon = icons.expanded
        else
          -- Collapsed collapsible node: use collapsed arrow
          tree_icon = icons.collapsed
        end

        -- Build the display line: indent + tree_icon + " " + [icon + " "] + label [+ " (description)"]
        local line = indent .. tree_icon .. " "
        -- Append the optional item icon if provided
        if item.icon then
          line = line .. item.icon.text .. " "
        end
        -- Append the main label text
        line = line .. item.label
        -- Append optional description in parentheses
        if item.description then
          line = line .. " (" .. item.description .. ")"
        end

        -- Add this line to the buffer content
        lines[#lines + 1] = line
        -- Track which element corresponds to which buffer line
        visible_nodes[#visible_nodes + 1] = { element = element, depth = depth }

        -- Recursively render children if this node is expanded
        if state.expanded and element.children then
          walk(element.children, depth + 1)
        end
      end
    end

    -- Start the recursive walk from root elements if available
    if self.roots then
      walk(self.roots, 0)
    end

    -- Write lines into the buffer (temporarily enable modifiable)
    vim.bo[self.buf].modifiable = true
    api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    vim.bo[self.buf].modifiable = false

    -- Clear all existing highlight extmarks in this namespace
    api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)

    -- Apply syntax highlights for each visible node
    for i, node in ipairs(visible_nodes) do
      local item = opts.get_tree_item(node.element)
      -- Calculate byte offset for the indentation portion
      local indent_bytes = #string.rep("  ", node.depth)

      -- Calculate byte length of the tree icon (collapsed/expanded/leaf)
      local tree_icon_bytes
      if not item.collapsible then
        tree_icon_bytes = #icons.leaf
      else
        local st = get_state(node.element)
        tree_icon_bytes = st.expanded and #icons.expanded or #icons.collapsed
      end

      -- Apply label highlight covering tree_icon through end of line (for directories, etc.)
      if item.label_hl and item.label_hl ~= "" then
        local line_end = #lines[i]
        api.nvim_buf_set_extmark(self.buf, ns, i - 1, indent_bytes, {
          end_col = line_end,
          hl_group = item.label_hl,
        })
      end

      -- Apply icon-specific highlight to just the icon text portion
      if item.icon and item.icon.hlGroup and item.icon.hlGroup ~= "" then
        -- Icon starts after indent + tree_icon + 1 space
        local icon_start = indent_bytes + tree_icon_bytes + 1
        -- Icon ends after icon text characters
        local icon_end = icon_start + #item.icon.text
        api.nvim_buf_set_extmark(self.buf, ns, i - 1, icon_start, {
          end_col = icon_end,
          hl_group = item.icon.hlGroup,
        })
      end

      -- Apply description highlight if both description and its hl group are present
      if item.description and item.description_hl then
        local line_str = lines[i]
        -- Find the description text position using plain string search
        local desc_start = line_str:find(item.description, 1, true)
        if desc_start then
          api.nvim_buf_set_extmark(self.buf, ns, i - 1, desc_start - 1, {
            end_col = desc_start - 1 + #item.description,
            hl_group = item.description_hl,
          })
        end
      end
    end
  end

  --- Automatically expands collapsible nodes up to the configured expand_level depth.
  ---@param elements any[]|nil List of elements to auto-expand
  ---@param depth integer Current depth level (starts at 1 for root)
  local function auto_expand(elements, depth)
    -- Stop recursion if we exceed the configured expand level or elements is nil
    if expand_level < depth or not elements then
      return
    end
    for _, element in ipairs(elements) do
      local item = opts.get_tree_item(element)
      -- Only expand nodes that are collapsible and actually have children
      if item.collapsible and element.children then
        local state = get_state(element)
        -- Mark as expanded
        state.expanded = true
        -- Recurse into children at the next depth level
        auto_expand(element.children, depth + 1)
      end
    end
  end

  --- Loads tree items either synchronously (from a table) or asynchronously (via callback).
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

  --- Returns the tree element at the current cursor position in the buffer.
  ---@return any|nil element The element at the cursor line, or nil if none
  local function get_element_at_cursor()
    -- Get the current cursor line number (1-based)
    local line = api.nvim_win_get_cursor(0)[1]
    -- Look up the node data for this line
    local node = visible_nodes[line]
    -- Return the element reference or nil
    return node and node.element or nil
  end

  -- Create a scratch buffer for the tree view (unlisted, scratch)
  self.buf = api.nvim_create_buf(false, true)
  -- Configure buffer options for a non-file, disposable buffer
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].swapfile = false
  vim.bo[self.buf].filetype = "git_tree"

  -- Set up the "select" keymap to emit a "select" event for the element under cursor
  vim.keymap.set("n", keys.select, function()
    local element = get_element_at_cursor()
    if element then
      -- Emit the "select" event so consumers can react to item activation
      self:emit("select", element)
    end
  end, { buffer = self.buf, silent = true })

  -- Set up the "toggle" keymap to expand/collapse collapsible nodes
  vim.keymap.set("n", keys.toggle, function()
    local element = get_element_at_cursor()
    if not element then
      return
    end
    local item = opts.get_tree_item(element)
    -- Only toggle if the node is collapsible (has children)
    if item.collapsible then
      -- Emit the "toggle" event before changing state
      self:emit("toggle", element)
      -- Flip the expanded state
      local state = get_state(element)
      state.expanded = not state.expanded
      -- Re-render the tree to reflect the new state
      render()
    end
  end, { buffer = self.buf, silent = true })

  -- Track the previously highlighted element to avoid redundant cursor events
  local prev_element = nil

  -- Set up a CursorMoved autocmd to emit "cursor" events when the selected item changes
  api.nvim_create_autocmd("CursorMoved", {
    buffer = self.buf,
    callback = function()
      local element = get_element_at_cursor()
      -- Only emit if the cursor moved to a different element
      if element and element ~= prev_element then
        prev_element = element
        -- Emit cursor event so consumers can show previews, etc.
        self:emit("cursor", element)
      end
    end,
  })

  --- Refreshes the tree view. If an element is given, collapses it and re-renders.
  --- If no element is given, reloads all items from scratch.
  ---@param element? any Optional element to collapse and re-render; nil reloads everything
  function self:refresh(element)
    if element then
      -- Collapse the specific element and re-render
      local state = get_state(element)
      state.expanded = false
      render()
    else
      -- Full reload: clear all states and reload items from the data source
      node_states = {}
      load_items(function(new_items)
        self.roots = new_items
        -- Apply auto-expand to the freshly loaded roots
        auto_expand(self.roots, 1)
        render()
      end)
    end
  end

  --- Programmatically toggles the expand/collapse state of a collapsible element.
  ---@param element any The element to toggle
  function self:toggle(element)
    local item = opts.get_tree_item(element)
    -- Only toggle collapsible nodes
    if item.collapsible then
      local state = get_state(element)
      -- Flip the expanded state
      state.expanded = not state.expanded
      -- Re-render the tree to reflect the change
      render()
    end
  end

  -- Perform the initial load of tree items
  load_items(function(new_items)
    -- Store the root items on the view instance
    self.roots = new_items
    -- Auto-expand nodes starting from depth 1
    auto_expand(self.roots, 1)
    -- Render the initial tree content
    render()

    -- If a current element is specified, position the cursor on it when the buffer enters a window
    if opts.current then
      -- Find the line number corresponding to the target element
      local target_line = 1
      for i, node in ipairs(visible_nodes) do
        if node.element == opts.current then
          target_line = i
          break
        end
      end
      -- Use BufWinEnter to set cursor after the buffer is displayed in a window
      api.nvim_create_autocmd("BufWinEnter", {
        buffer = self.buf,
        once = true,
        callback = function()
          -- Verify the window is actually showing our buffer before setting cursor
          local win = api.nvim_get_current_win()
          if api.nvim_win_get_buf(win) == self.buf then
            api.nvim_win_set_cursor(win, { target_line, 0 })
          end
        end,
      })
    end
  end)

  return self
end

return M
