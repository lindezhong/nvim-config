-- treeview.lua: Generic tree view component.
--
-- Implements the TreeView + TreeDataProvider pattern (coc.nvim / VS Code style).
-- This module handles ALL UI concerns:
--   - Side panel creation and lifecycle management
--   - Tree rendering (indent, icons, expand/collapse states)
--   - Keyboard navigation and interaction
--   - viewId-based singleton management (same viewId replaces existing panel)
--   - Auto-expand on initial show
--   - Event system for external listeners
--
-- Caller only needs to provide:
--   - TreeDataProvider: get_children(element, callback) + get_tree_item(element)
--   - on_select callback for node activation
--
-- This module does NOT know about LSP, call hierarchy, or any business logic.

--------------------------------------------------------------------------
-- Type definitions
--------------------------------------------------------------------------

---@class TreeItem
---@field label string display text for the node
---@field collapsible boolean whether this node can have children (expandable)
---@field icon? string custom prefix icon (overrides default expand/collapse icons)
---@field description? string secondary text shown after label in parentheses

---@class TreeDataProvider
---@field get_children fun(element?: any, callback: fun(children: any[])) async fetch children; nil element = fetch roots
---@field get_tree_item fun(element: any): TreeItem convert domain element to display node
---@field on_did_change_tree_data? fun(callback: fun(element?: any)) register listener for data changes

---@class TreeViewKeys
---@field toggle? string key to expand/collapse node (default "<Tab>")
---@field select? string key to activate/invoke action (default "<CR>")
---@field close? string key to close panel (default "q")

---@class TreeViewIcons
---@field collapsed? string icon for collapsed node (default "+")
---@field expanded? string icon for expanded node (default "-")
---@field leaf? string icon for leaf node (default " ")

---@class TreeViewOpts
---@field viewId? string unique id; same viewId replaces existing instance (singleton pattern)
---@field title? string panel title shown in statusline
---@field provider TreeDataProvider data source for the tree
---@field on_select? fun(element: any) called when user activates a node (Enter)
---@field expand_level? integer auto-expand depth on show (default 0, no auto-expand)
---@field width? integer panel width for left/right position (default 40)
---@field height? integer panel height for top/bottom position (default 15)
---@field position? "left"|"right"|"top"|"bottom" panel position (default "right")
---@field keys? TreeViewKeys custom key bindings
---@field icons? TreeViewIcons custom icons

local M = {}

--- Global registry for viewId-based singleton management.
--- Maps viewId → TreeView instance. When creating with an existing viewId,
--- the previous instance is disposed first to avoid duplicate panels.
---@type table<string, table>
local registry = {}

--- Create a new TreeView instance.
--- If opts.viewId matches an existing instance, the old one is disposed first.
---@param opts TreeViewOpts creation options
---@return table TreeView the view handle with show/hide/refresh/dispose methods
function M.create(opts)
  -- Dispose existing instance with same viewId (singleton pattern)
  if opts.viewId and registry[opts.viewId] then
    registry[opts.viewId].dispose()
  end

  -- Extract options with defaults
  local provider = opts.provider
  local keys = vim.tbl_extend("keep", opts.keys or {}, {
    toggle = "<Tab>",  -- expand/collapse
    select = "<CR>",   -- activate node
    close = "q",       -- close panel
  })
  local icons = vim.tbl_extend("keep", opts.icons or {}, {
    collapsed = "+",   -- node has children, currently closed
    expanded = "-",    -- node has children, currently open
    leaf = " ",        -- node has no children
  })
  local width = opts.width or 40          -- panel width (left/right position)
  local height = opts.height or 15        -- panel height (top/bottom position)
  local position = opts.position or "right"  -- panel placement
  local expand_level = opts.expand_level or 0  -- 0 = no auto-expand

  --- Sentinel object used as table key for root node state.
  --- In Lua, nil cannot be used as a table key; this empty table acts
  --- as a unique non-nil stand-in for the "nil element = root" case.
  ---@type table
  local ROOT = {}

  --------------------------------------------------------------------------
  -- Internal state
  --------------------------------------------------------------------------

  local tree_buf = nil       ---@type integer? buffer number of the tree panel
  local tree_win = nil       ---@type integer? window id of the tree panel
  local visible_nodes = {}   ---@type {element: any, depth: integer}[] index = line number in buffer
  local node_states = {}     ---@type table<any, {expanded: boolean, children: any[]?, loading: boolean}> element|ROOT → state
  local disposed = false     ---@type boolean whether this instance has been disposed

  --- Event listeners registry. Keyed by event name, value is array of callbacks.
  ---@type table<string, fun(...)[]>
  local listeners = {
    expand = {},      -- fired when a node is expanded
    collapse = {},    -- fired when a node is collapsed
    selection = {},   -- fired when cursor moves to a different node
    visibility = {},  -- fired when panel is shown or hidden
  }

  --- Fire an event to all registered listeners.
  ---@param event string event name (expand|collapse|selection|visibility)
  ---@param ... any arguments passed to listeners
  local function fire(event, ...)
    for _, cb in ipairs(listeners[event] or {}) do
      cb(...)
    end
  end

  --- Get or create the state object for an element.
  --- Uses ROOT sentinel for the nil element (tree root).
  ---@param element any? the tree element (nil for root)
  ---@return {expanded: boolean, children: any[]?, loading: boolean}
  local function get_state(element)
    local key = element or ROOT  -- use ROOT sentinel for nil element
    if not node_states[key] then
      node_states[key] = { expanded = false, children = nil, loading = false }
    end
    return node_states[key]
  end

  --------------------------------------------------------------------------
  -- Rendering
  --------------------------------------------------------------------------

  --- Render the entire tree into the buffer.
  --- Walks the tree depth-first, building lines array and visible_nodes mapping.
  --- visible_nodes[line_number] = {element, depth} allows cursor↔element lookup.
  local function render()
    if not tree_buf or not vim.api.nvim_buf_is_valid(tree_buf) then return end
    local lines = {}       -- buffer lines to set
    visible_nodes = {}     -- reset line→element mapping

    --- Recursive walk: render elements at a given depth.
    ---@param elements any[] elements to render at this level
    ---@param depth integer current indentation depth (0 = root level)
    local function walk(elements, depth)
      for _, element in ipairs(elements) do
        local item = provider.get_tree_item(element)  -- get display properties
        local state = get_state(element)               -- get expand/collapse state
        local indent = string.rep("  ", depth)         -- 2 spaces per depth level

        -- Determine the icon to show before the label
        local icon
        if item.icon then
          icon = item.icon                -- custom icon takes priority
        elseif not item.collapsible then
          icon = icons.leaf               -- leaf node (no children possible)
        elseif state.expanded then
          icon = icons.expanded           -- open node with children
        else
          icon = icons.collapsed          -- closed node with children
        end

        -- Build the display line: [indent][icon] [label] [(description)]
        local line = indent .. icon .. " " .. item.label
        if item.description then
          line = line .. " (" .. item.description .. ")"
        end

        -- Add to buffer lines and track element at this line number
        table.insert(lines, line)
        table.insert(visible_nodes, { element = element, depth = depth })

        -- Recurse into children if this node is expanded and has children loaded
        if state.expanded and state.children then
          walk(state.children, depth + 1)
        end
      end
    end

    -- Start walk from root children
    local root_state = get_state(nil)
    if root_state.children then
      walk(root_state.children, 0)
    end

    -- Update buffer content (must toggle modifiable since buffer is read-only)
    vim.bo[tree_buf].modifiable = true
    vim.api.nvim_buf_set_lines(tree_buf, 0, -1, false, lines)
    vim.bo[tree_buf].modifiable = false
  end

  --- Get the element at the current cursor position in the tree window.
  ---@return any? element the element at cursor, or nil if no valid selection
  local function get_element_at_cursor()
    if not tree_win or not vim.api.nvim_win_is_valid(tree_win) then return nil end
    local row = vim.api.nvim_win_get_cursor(tree_win)[1]  -- 1-indexed line number
    local node = visible_nodes[row]
    return node and node.element or nil
  end

  --------------------------------------------------------------------------
  -- Node operations (expand/collapse/toggle)
  --------------------------------------------------------------------------

  --- Expand a node: fetch children asynchronously, then re-render.
  --- If children are already cached, expands immediately without fetching.
  ---@param element any the element to expand
  local function expand(element)
    local state = get_state(element)
    -- Don't expand if already loading (prevents duplicate requests)
    if state.loading then return end
    -- If children already cached, just mark expanded and render
    if state.children then
      state.expanded = true
      render()
      fire("expand", element)
      return
    end
    -- Fetch children asynchronously from provider
    state.loading = true
    provider.get_children(element, function(children)
      state.loading = false
      state.children = children or {}
      state.expanded = true
      render()
      fire("expand", element)
    end)
  end

  --- Collapse a node: hide its children without clearing the cache.
  ---@param element any the element to collapse
  local function collapse(element)
    local state = get_state(element)
    state.expanded = false
    render()
    fire("collapse", element)
  end

  --- Toggle expand/collapse for the node at cursor.
  --- Does nothing for leaf nodes (not collapsible).
  local function toggle()
    local element = get_element_at_cursor()
    if not element then return end
    local item = provider.get_tree_item(element)
    if not item.collapsible then return end  -- leaf nodes can't be toggled
    local state = get_state(element)
    if state.expanded then
      collapse(element)
    else
      expand(element)
    end
  end

  --- Handle "select" action (Enter key) on the node at cursor.
  --- Delegates to the opts.on_select callback provided by the caller.
  local function select_node()
    local element = get_element_at_cursor()
    if not element then return end
    if opts.on_select then
      opts.on_select(element)
    end
  end

  --------------------------------------------------------------------------
  -- Auto-expand
  --------------------------------------------------------------------------

  --- Recursively auto-expand collapsible nodes up to expand_level depth.
  --- Used on initial show to present a useful starting view without user interaction.
  --- Fetches children for all collapsible nodes at current depth, then recurses.
  ---@param elements any[] elements to consider for auto-expanding
  ---@param depth integer current depth level (starts at 1 for root children)
  local function auto_expand(elements, depth)
    -- Stop recursion if we've reached the target depth or no elements
    if expand_level < depth or not elements or #elements == 0 then
      render()
      return
    end

    -- Collect only collapsible elements (leaf nodes don't need expanding)
    local collapsible = {}
    for _, element in ipairs(elements) do
      if provider.get_tree_item(element).collapsible then
        table.insert(collapsible, element)
      end
    end

    -- If nothing to expand at this depth, just render current state
    if #collapsible == 0 then
      render()
      return
    end

    -- Fetch children for all collapsible nodes, then recurse to next depth
    local pending = #collapsible  -- counter for async completion tracking
    local function on_all_expanded()
      -- All nodes at this depth are expanded; check if we should go deeper
      if depth >= expand_level then
        render()
        return
      end
      -- Collect all children from expanded nodes for next depth iteration
      local next_elements = {}
      for _, el in ipairs(collapsible) do
        for _, child in ipairs(get_state(el).children or {}) do
          table.insert(next_elements, child)
        end
      end
      auto_expand(next_elements, depth + 1)
    end

    -- Fetch children for each collapsible node asynchronously
    for _, element in ipairs(collapsible) do
      local state = get_state(element)
      state.loading = true
      provider.get_children(element, function(children)
        state.loading = false
        state.children = children or {}
        state.expanded = true
        pending = pending - 1
        -- When all nodes at this depth are done, continue to next depth
        if pending == 0 then on_all_expanded() end
      end)
    end
  end

  --------------------------------------------------------------------------
  -- Panel management
  --------------------------------------------------------------------------

  --- Generate the split command for creating the panel window.
  --- Maps position option to appropriate Neovim split command.
  ---@return string vim split command
  local function split_cmd()
    if position == "right" then
      return "botright " .. width .. "vsplit"
    elseif position == "left" then
      return "topleft " .. width .. "vsplit"
    elseif position == "bottom" then
      return "botright " .. height .. "split"
    elseif position == "top" then
      return "topleft " .. height .. "split"
    end
    return "botright " .. width .. "vsplit"  -- fallback to right
  end

  --- Create a scratch buffer for the tree panel.
  --- Configured as nofile/wipe so it doesn't persist and cleans up on close.
  ---@return integer buf buffer number of the created scratch buffer
  local function create_buf()
    local buf = vim.api.nvim_create_buf(false, true)  -- unlisted, scratch
    vim.bo[buf].buftype = "nofile"     -- not associated with a file
    vim.bo[buf].bufhidden = "wipe"     -- delete buffer when hidden
    vim.bo[buf].filetype = "treeview"  -- for filetype-specific autocmds
    return buf
  end

  -- Forward declaration for view table.
  -- Needed because setup_keymaps closure references view.hide(),
  -- but view methods are defined later. Lua locals are only visible
  -- after their declaration point in the same block.
  local view = {}

  --- Set up key mappings on the tree buffer.
  --- All mappings are buffer-local (only active in the tree panel).
  local function setup_keymaps()
    local map_opts = { buffer = tree_buf, nowait = true }
    vim.keymap.set("n", keys.toggle, toggle, map_opts)       -- Tab: expand/collapse
    vim.keymap.set("n", keys.select, select_node, map_opts)  -- Enter: activate
    vim.keymap.set("n", keys.close, function()
      view.hide()  -- q: close panel
    end, map_opts)
  end

  --- Set up cursor movement tracking to fire selection change events.
  --- Fires "selection" event only when cursor moves to a DIFFERENT node.
  local prev_element = nil  ---@type any? previously selected element for dedup
  local function setup_cursor_tracking()
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = tree_buf,
      callback = function()
        local element = get_element_at_cursor()
        -- Only fire event if selection actually changed (dedup)
        if element ~= prev_element then
          prev_element = element
          if element then
            fire("selection", element)
          end
        end
      end,
    })
  end

  --------------------------------------------------------------------------
  -- Public API (TreeView handle)
  --------------------------------------------------------------------------

  --- Show the tree panel. If already visible, refreshes content.
  --- Creates buffer + window on first call, fetches root children.
  function view.show()
    if disposed then return end
    -- If window still valid, just refresh the content
    if tree_win and vim.api.nvim_win_is_valid(tree_win) then
      render()
      return
    end
    -- Create buffer and open split window
    tree_buf = create_buf()
    vim.cmd(split_cmd())
    tree_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(tree_win, tree_buf)
    -- Configure window appearance (minimal chrome)
    vim.wo[tree_win].number = false
    vim.wo[tree_win].relativenumber = false
    vim.wo[tree_win].signcolumn = "no"
    vim.wo[tree_win].wrap = false
    vim.wo[tree_win].statusline = opts.title and (" " .. opts.title) or " "

    setup_keymaps()
    setup_cursor_tracking()

    -- Fetch root children if not already loaded
    local root_state = get_state(nil)
    if not root_state.children then
      provider.get_children(nil, function(children)
        root_state.children = children or {}
        -- Auto-expand root children to configured depth
        auto_expand(root_state.children, 1)
      end)
    else
      render()  -- roots already cached, just render
    end

    fire("visibility", true)
  end

  --- Hide the tree panel (close window, keep state for re-show).
  function view.hide()
    if tree_win and vim.api.nvim_win_is_valid(tree_win) then
      vim.api.nvim_win_close(tree_win, true)  -- force close
      vim.cmd("mode")  -- redraw to clear any artifacts
    end
    tree_win = nil
    fire("visibility", false)
  end

  --- Refresh tree data. If element is given, only re-fetches that subtree.
  --- If element is nil, does a full refresh (clears all state, re-fetches roots).
  ---@param element any? specific element to refresh, or nil for full refresh
  function view.refresh(element)
    if element then
      -- Partial refresh: clear children cache and re-expand if was expanded
      local state = get_state(element)
      state.children = nil
      if state.expanded then
        expand(element)
      end
    else
      -- Full refresh: clear all state and re-fetch from scratch
      node_states = {}
      provider.get_children(nil, function(children)
        local root_state = get_state(nil)
        root_state.children = children or {}
        render()
      end)
    end
  end

  --- Dispose this tree view instance completely.
  --- Closes panel, clears state, removes from registry. Cannot be reused after.
  function view.dispose()
    if disposed then return end
    disposed = true
    view.hide()
    -- Remove from singleton registry
    if opts.viewId then
      registry[opts.viewId] = nil
    end
    -- Clear all internal state
    node_states = {}
    visible_nodes = {}
    listeners = { expand = {}, collapse = {}, selection = {}, visibility = {} }
  end

  --------------------------------------------------------------------------
  -- Event registration methods
  --------------------------------------------------------------------------

  --- Register a callback for when a node is expanded.
  ---@param callback fun(element: any)
  function view.on_did_expand(callback)
    table.insert(listeners.expand, callback)
  end

  --- Register a callback for when a node is collapsed.
  ---@param callback fun(element: any)
  function view.on_did_collapse(callback)
    table.insert(listeners.collapse, callback)
  end

  --- Register a callback for when cursor moves to a different node.
  ---@param callback fun(element: any)
  function view.on_did_change_selection(callback)
    table.insert(listeners.selection, callback)
  end

  --- Register a callback for when panel visibility changes.
  ---@param callback fun(visible: boolean)
  function view.on_did_change_visibility(callback)
    table.insert(listeners.visibility, callback)
  end

  --------------------------------------------------------------------------
  -- Data provider change subscription
  --------------------------------------------------------------------------

  -- If provider supports change notifications, subscribe to auto-refresh
  if provider.on_did_change_tree_data then
    provider.on_did_change_tree_data(function(element)
      view.refresh(element)
    end)
  end

  -- Register in global singleton registry
  if opts.viewId then
    registry[opts.viewId] = view
  end

  return view
end

return M
