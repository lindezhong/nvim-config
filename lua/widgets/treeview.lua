-- treeview.lua: Generic tree view component.
--
-- Implements the TreeView + TreeDataProvider pattern (coc.nvim / VS Code style).
-- Shared by the git plugin (diff file tree) and LSP panels (outline, call hierarchy).
--
-- Two usage modes:
--   - Panel mode: pass position (and optionally viewId/title/width) — the view
--     creates and manages its own side panel (show/hide/dispose, viewId
--     singleton reuse). "q" closes the panel.
--   - Buffer mode: omit position — the view only creates .buf; the consumer
--     places it into a window (e.g. via widgets.window/layout) and drives
--     the lifecycle via :close().
--
-- Data source, either:
--   - items: full tree upfront (table, or callback-style); children nested
--     on element.children; requires get_tree_item
--   - provider.get_children(element, callback): async lazy loading per node
--
-- Events (via :on): "select" (<CR>), "cursor" (CursorMoved), "toggle" (<Tab>),
-- "expand", "collapse", "visibility".

local view = require("widgets.view")

local api = vim.api

---@class TreeItemIcon
---@field text string icon text shown between the toggle indicator and the label
---@field hlGroup? string highlight group for the icon

---@class TreeItem
---@field label string display text for the node
---@field collapsible boolean whether this node can have children (expandable)
---@field icon? TreeItemIcon optional icon (kind/status marker), does not replace the toggle indicator
---@field label_hl? string highlight group covering the line from indent to end
---@field description? string secondary text shown after label in parentheses
---@field description_hl? string highlight group for the description

---@class TreeDataProvider
---@field get_children fun(element?: any, callback: fun(children: any[])) async fetch children; nil element = roots
---@field get_tree_item fun(element: any): TreeItem convert domain element to display node
---@field on_did_change_tree_data? fun(callback: fun(element?: any)) register listener for data changes

---@class TreeViewKeys
---@field toggle? string key to expand/collapse node (default "<Tab>")
---@field select? string key to activate/invoke action (default "<CR>")
---@field close? string key to close panel (default "q", panel mode only)

---@class TreeViewIcons
---@field collapsed? string icon for collapsed node (default "▸")
---@field expanded? string icon for expanded node (default "▾")
---@field leaf? string icon for leaf node (default " ")

---@class TreeViewOpts
---@field items? any[] | fun(callback: fun(items: any[])) full tree upfront; requires get_tree_item
---@field get_tree_item? fun(element: any): TreeItem element → TreeItem (required with items)
---@field provider? TreeDataProvider async lazy-loading data source
---@field viewId? string unique id; same viewId reuses the panel instance (swaps provider)
---@field title? string panel title shown in statusline
---@field on_select? fun(element: any) called on <CR> (also emitted as "select")
---@field expand_level? integer auto-expand depth on load (default 0)
---@field current? any element to place the cursor on after load
---@field width? integer panel width for left/right (default 40)
---@field height? integer panel height for top/bottom (default 15)
---@field position? "left"|"right"|"top"|"bottom" panel position; omit = buffer-only mode
---@field keys? TreeViewKeys custom key bindings
---@field icons? TreeViewIcons custom icons

--- Global registry for viewId-based singleton management.
---@type table<string, table>
local registry = {}

--- Namespace for extmark highlights
local ns = api.nvim_create_namespace("widgets_tree")

local M = {}

--- Create a new TreeView instance.
--- If opts.viewId matches an existing instance, reuses it with the new provider.
---@param opts TreeViewOpts creation options
---@return table tree the view handle with show/hide/refresh/toggle/close methods
function M.create(opts)
  -- Reuse existing instance with same viewId (avoids dispose+recreate flicker)
  if opts.viewId and registry[opts.viewId] then
    local existing = registry[opts.viewId]
    existing.set_provider(opts.provider, opts.on_select)
    return existing
  end

  -- Event emitter and lifecycle base
  local self = view.create()

  -- Normalize items → provider so rendering has a single data interface
  local provider
  if opts.items then
    provider = {
      get_children = function(element, callback)
        if element then
          callback(element.children or {})
        elseif type(opts.items) == "function" then
          opts.items(callback)
        else
          callback(opts.items)
        end
      end,
      get_tree_item = opts.get_tree_item,
    }
  else
    provider = opts.provider
  end

  local keys = vim.tbl_extend("keep", opts.keys or {}, {
    toggle = "<Tab>",
    select = "<CR>",
    close = "q",
  })
  local icons = vim.tbl_extend("keep", opts.icons or {}, {
    collapsed = "▸",
    expanded = "▾",
    leaf = " ",
  })
  local width = opts.width or 40
  local height = opts.height or 15
  local position = opts.position
  local expand_level = opts.expand_level or 0

  --- Sentinel used as table key for root node state (nil cannot be a table key).
  ---@type table
  local ROOT = {}

  local tree_buf = nil       ---@type integer? buffer number
  local tree_win = nil       ---@type integer? window id (panel mode only)
  local visible_nodes = {}   ---@type {element: any, depth: integer}[] index = line number
  local node_states = {}     ---@type table<any, {expanded: boolean, children: any[]?, loading: boolean}>
  local disposed = false     ---@type boolean
  local prev_element = nil   ---@type any? last element under the cursor (cursor event dedup)

  --- Get or create the state object for an element (ROOT sentinel for nil).
  ---@param element any?
  ---@return {expanded: boolean, children: any[]?, loading: boolean}
  local function get_state(element)
    local key = element or ROOT
    if not node_states[key] then
      node_states[key] = { expanded = false, children = nil, loading = false }
    end
    return node_states[key]
  end

  --------------------------------------------------------------------------
  -- Rendering
  --------------------------------------------------------------------------

  --- Render the entire tree into the buffer.
  local function render()
    if not tree_buf or not vim.api.nvim_buf_is_valid(tree_buf) then return end
    local lines = {}
    visible_nodes = {}

    --- Recursive walk: build display lines for elements at a given depth.
    ---@param elements any[]
    ---@param depth integer
    local function walk(elements, depth)
      for _, element in ipairs(elements) do
        local item = provider.get_tree_item(element)
        local state = get_state(element)
        local indent = string.rep("  ", depth)

        -- Toggle indicator column: leaf icon / expand state
        local tree_icon
        if not item.collapsible then
          tree_icon = icons.leaf
        elseif state.expanded then
          tree_icon = icons.expanded
        else
          tree_icon = icons.collapsed
        end

        -- Line layout: [indent][tree_icon] [icon] [label] [(description)]
        local line = indent .. tree_icon .. " "
        if item.icon then
          line = line .. item.icon.text .. " "
        end
        line = line .. item.label
        if item.description then
          line = line .. " (" .. item.description .. ")"
        end

        lines[#lines + 1] = line
        visible_nodes[#visible_nodes + 1] = { element = element, depth = depth }

        if state.expanded and state.children then
          walk(state.children, depth + 1)
        end
      end
    end

    local root_state = get_state(nil)
    if root_state.children then
      walk(root_state.children, 0)
    end

    vim.bo[tree_buf].modifiable = true
    api.nvim_buf_set_lines(tree_buf, 0, -1, false, lines)
    vim.bo[tree_buf].modifiable = false

    -- Apply highlights (extmarks), recomputing column offsets per line
    api.nvim_buf_clear_namespace(tree_buf, ns, 0, -1)
    for i, node in ipairs(visible_nodes) do
      local item = provider.get_tree_item(node.element)
      local indent_bytes = #string.rep("  ", node.depth)

      local tree_icon_bytes
      if not item.collapsible then
        tree_icon_bytes = #icons.leaf
      else
        local st = get_state(node.element)
        tree_icon_bytes = st.expanded and #icons.expanded or #icons.collapsed
      end

      if item.label_hl and item.label_hl ~= "" then
        api.nvim_buf_set_extmark(tree_buf, ns, i - 1, indent_bytes, {
          end_col = #lines[i],
          hl_group = item.label_hl,
        })
      end

      if item.icon and item.icon.hlGroup and item.icon.hlGroup ~= "" then
        local icon_start = indent_bytes + tree_icon_bytes + 1
        api.nvim_buf_set_extmark(tree_buf, ns, i - 1, icon_start, {
          end_col = icon_start + #item.icon.text,
          hl_group = item.icon.hlGroup,
        })
      end

      if item.description and item.description_hl then
        local desc_start = lines[i]:find(item.description, 1, true)
        if desc_start then
          api.nvim_buf_set_extmark(tree_buf, ns, i - 1, desc_start - 1, {
            end_col = desc_start - 1 + #item.description,
            hl_group = item.description_hl,
          })
        end
      end
    end
  end

  --- Get the element at the cursor in the tree window.
  ---@return any?
  local function get_element_at_cursor()
    local win = tree_win
    if not win or not vim.api.nvim_win_is_valid(win) then win = 0 end
    local node = visible_nodes[api.nvim_win_get_cursor(win)[1]]
    return node and node.element or nil
  end

  --------------------------------------------------------------------------
  -- Node operations (expand/collapse/toggle)
  --------------------------------------------------------------------------

  --- Expand a node: fetch children from the provider, then re-render.
  local function expand(element)
    local state = get_state(element)
    if state.loading then return end
    if state.children then
      state.expanded = true
      render()
      self:emit("expand", element)
      return
    end
    state.loading = true
    provider.get_children(element, function(children)
      state.loading = false
      state.children = children or {}
      state.expanded = true
      render()
      self:emit("expand", element)
    end)
  end

  --- Collapse a node without clearing its children cache.
  local function collapse(element)
    local state = get_state(element)
    state.expanded = false
    render()
    self:emit("collapse", element)
  end

  --- Flip the expand state (expand() fetches children if not cached yet).
  local function toggle_element(element)
    local state = get_state(element)
    if state.expanded then
      collapse(element)
    else
      expand(element)
    end
  end

  --- Toggle expand/collapse. Supports both tree.toggle(element) and tree:toggle(element).
  ---@param a any element (dot call) or the view itself (colon call)
  ---@param b any? element when called with a colon
  function self.toggle(a, b)
    local element = b or a
    local item = provider.get_tree_item(element)
    if not item.collapsible then return end
    self:emit("toggle", element)
    toggle_element(element)
  end

  --- Activate the node at the cursor: emit "select" and call on_select.
  local function select_node()
    local element = get_element_at_cursor()
    if not element then return end
    self:emit("select", element)
    if opts.on_select then
      opts.on_select(element)
    end
  end

  --------------------------------------------------------------------------
  -- Auto-expand
  --------------------------------------------------------------------------

  --- Recursively auto-expand collapsible nodes up to expand_level depth,
  --- fetching children for each level before recursing deeper.
  ---@param elements any[]? elements at the current depth
  ---@param depth integer current depth (starts at 1 for root children)
  ---@param on_done function? called after the final render
  local function auto_expand(elements, depth, on_done)
    if expand_level < depth or not elements or #elements == 0 then
      render()
      if on_done then on_done() end
      return
    end

    local collapsible = {}
    for _, element in ipairs(elements) do
      if provider.get_tree_item(element).collapsible then
        collapsible[#collapsible + 1] = element
      end
    end

    if #collapsible == 0 then
      render()
      if on_done then on_done() end
      return
    end

    local pending = #collapsible
    local function on_all_expanded()
      if depth >= expand_level then
        render()
        if on_done then on_done() end
        return
      end
      local next_elements = {}
      for _, el in ipairs(collapsible) do
        for _, child in ipairs(get_state(el).children or {}) do
          next_elements[#next_elements + 1] = child
        end
      end
      auto_expand(next_elements, depth + 1, on_done)
    end

    for _, element in ipairs(collapsible) do
      local state = get_state(element)
      state.loading = true
      provider.get_children(element, function(children)
        state.loading = false
        state.children = children or {}
        state.expanded = true
        pending = pending - 1
        if pending == 0 then on_all_expanded() end
      end)
    end
  end

  --- Move the cursor to opts.current once the tree is rendered.
  --- If the buffer is already in a window, moves now; otherwise defers to
  --- the first BufWinEnter (consumer places the buffer afterwards).
  local function setup_current()
    if not opts.current then return end
    local target_line = 1
    for i, node in ipairs(visible_nodes) do
      if node.element == opts.current then
        target_line = i
        break
      end
    end
    if tree_win and vim.api.nvim_win_is_valid(tree_win)
        and vim.api.nvim_win_get_buf(tree_win) == tree_buf then
      api.nvim_win_set_cursor(tree_win, { target_line, 0 })
      return
    end
    api.nvim_create_autocmd("BufWinEnter", {
      buffer = tree_buf,
      once = true,
      callback = function()
        local win = api.nvim_get_current_win()
        if vim.api.nvim_win_get_buf(win) == tree_buf then
          api.nvim_win_set_cursor(win, { target_line, 0 })
        end
      end,
    })
  end

  --- Load roots, auto-expand, position cursor.
  local function initial_load()
    provider.get_children(nil, function(children)
      local root_state = get_state(nil)
      root_state.children = children or {}
      auto_expand(root_state.children, 1, setup_current)
    end)
  end

  --------------------------------------------------------------------------
  -- Panel management
  --------------------------------------------------------------------------

  --- Generate the split command for the panel window.
  ---@return string
  local function split_cmd()
    if position == "left" then
      return "topleft " .. width .. "vsplit"
    elseif position == "top" then
      return "topleft " .. height .. "split"
    elseif position == "bottom" then
      return "botright " .. height .. "split"
    end
    return "botright " .. width .. "vsplit"
  end

  --- Create the scratch buffer for the tree.
  local function create_buf()
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "treeview"
    return buf
  end

  --- Buffer-local keymaps.
  local function setup_keymaps()
    local map_opts = { buffer = tree_buf, nowait = true, silent = true }
    vim.keymap.set("n", keys.toggle, function()
      local element = get_element_at_cursor()
      if element then self.toggle(element) end
    end, map_opts)
    vim.keymap.set("n", keys.select, select_node, map_opts)
    if position then
      vim.keymap.set("n", keys.close, function() self.hide() end, map_opts)
    end
  end

  --- Cursor tracking: emit "cursor" when the node under the cursor changes.
  local function setup_cursor_tracking()
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = tree_buf,
      callback = function()
        local element = get_element_at_cursor()
        if element and element ~= prev_element then
          prev_element = element
          self:emit("cursor", element)
        end
      end,
    })
  end

  --- Show the panel and load data (panel mode only).
  --- Reuses the window if already open; fetches roots if not loaded yet.
  function self.show()
    if disposed then return end

    local win_valid = tree_win and vim.api.nvim_win_is_valid(tree_win)
    local buf_valid = tree_buf and vim.api.nvim_buf_is_valid(tree_buf)
    if win_valid and buf_valid then
      vim.api.nvim_set_current_win(tree_win)
    else
      if win_valid then vim.api.nvim_win_close(tree_win, true) end
      tree_buf = create_buf()
      vim.cmd(split_cmd())
      tree_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(tree_win, tree_buf)
      vim.wo[tree_win].number = false
      vim.wo[tree_win].relativenumber = false
      vim.wo[tree_win].signcolumn = "no"
      vim.wo[tree_win].wrap = false
      vim.wo[tree_win].statusline = opts.title and (" " .. opts.title) or " "
      setup_keymaps()
      setup_cursor_tracking()
      self:emit("visibility", true)
    end

    local root_state = get_state(nil)
    if not root_state.children then
      provider.get_children(nil, function(children)
        root_state.children = children or {}
        auto_expand(root_state.children, 1, setup_current)
      end)
    else
      render()
    end
  end

  --- Hide the panel window (panel mode only); buffer and state are kept.
  function self.hide()
    if tree_win and vim.api.nvim_win_is_valid(tree_win) then
      vim.api.nvim_win_close(tree_win, true)
      vim.cmd("mode")
    end
    tree_win = nil
    self:emit("visibility", false)
  end

  --- Refresh tree data. With an element, re-fetches that subtree (and
  --- re-expands it if it was open); without, re-fetches from the roots.
  ---@param element any?
  function self.refresh(element)
    if element then
      local state = get_state(element)
      state.children = nil
      if state.expanded then
        expand(element)
      end
    else
      node_states = {}
      provider.get_children(nil, function(children)
        local root_state = get_state(nil)
        root_state.children = children or {}
        render()
      end)
    end
  end

  --- Dispose this instance: close the panel, delete the buffer, drop from
  --- the registry. Cannot be reused afterwards.
  function self.dispose()
    if disposed then return end
    disposed = true
    self:emit("close")
    self.hide()
    if opts.viewId then
      registry[opts.viewId] = nil
    end
    if tree_buf and vim.api.nvim_buf_is_valid(tree_buf) then
      vim.api.nvim_buf_delete(tree_buf, { force = true })
    end
    tree_buf = nil
    node_states = {}
    visible_nodes = {}
    self.listeners = {}
  end

  --- Alias for dispose (buffer-mode consumers use tree:close()).
  function self.close()
    self.dispose()
  end

  --- Replace the data provider and on_select (viewId reuse path).
  ---@param new_provider TreeDataProvider
  ---@param new_on_select? fun(element: any)
  function self.set_provider(new_provider, new_on_select)
    if disposed then return end
    provider = new_provider
    opts.on_select = new_on_select
    node_states = {}
    visible_nodes = {}
    prev_element = nil
    render()
    if provider.on_did_change_tree_data then
      provider.on_did_change_tree_data(function(element)
        self.refresh(element)
      end)
    end
  end

  -- Buffer mode: create the buffer up front for the consumer to place and
  -- load immediately (panel mode creates the buffer and loads in show())
  self.buf = nil
  if not position then
    tree_buf = create_buf()
    self.buf = tree_buf
    setup_keymaps()
    setup_cursor_tracking()
    initial_load()
  end

  -- Register in the singleton registry (panel mode)
  if opts.viewId then
    registry[opts.viewId] = self
  end

  return self
end

return M
