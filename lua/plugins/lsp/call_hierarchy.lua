-- call_hierarchy.lua: LSP incoming call hierarchy viewer.
--
-- Displays a tree of incoming callers for the symbol under cursor.
-- Strategy:
--   1. Primary: callHierarchy/incomingCalls — standard LSP call hierarchy
--   2. Fallback: textDocument/references — captures usage patterns not covered
--      by call hierarchy
--
-- Architecture:
--   - UI: delegated entirely to treeview.lua (tree rendering, panel, keys)
--   - LSP: delegated to lsp.lua (coroutine requests, coordinate conversion)
--   - This file: configuration, TreeDataProvider implementation, node construction
--
-- Node types:
--   - Call node (is_ref=false): from callHierarchy/incomingCalls result
--   - Ref node (is_ref=true): from textDocument/references fallback
--   Both types carry uri, def_lnum, def_col for further expansion via
--   prepareCallHierarchy at the definition position.

local lsp = require("plugins.lsp.lsp")
local treeview = require("plugins.lsp.treeview")
local goto_loc = require("plugins.lsp.goto")

--------------------------------------------------------------------------
-- Configuration (user-overridable via vim.g.*)
--------------------------------------------------------------------------

--- Panel width in columns.
---@type integer
vim.g.call_hierarchy_width = vim.g.call_hierarchy_width or 40

--- Total operation timeout in milliseconds (shared across all requests in one expand).
---@type integer
vim.g.call_hierarchy_timeout = vim.g.call_hierarchy_timeout or 10000

--- Key bindings for the call hierarchy tree panel.
---@type {toggle: string, select: string, close: string}
vim.g.call_hierarchy_keys = vim.tbl_extend("keep", vim.g.call_hierarchy_keys or {}, {
  toggle = "<Tab>",  -- expand/collapse node
  select = "<CR>",   -- jump to call site
  close = "q",       -- close panel
})

--- Icons for the call hierarchy tree panel.
---@type {collapsed: string, expanded: string, leaf: string, ref_prefix: string}
vim.g.call_hierarchy_icons = vim.tbl_extend("keep", vim.g.call_hierarchy_icons or {}, {
  collapsed = "+",   -- node with children, closed
  expanded = "-",    -- node with children, open
  leaf = "-",        -- node that cannot be expanded further
  ref_prefix = "*",  -- prefix for reference-based nodes (vs call-based)
})

--- SymbolKind values that represent callable containers.
--- Controls two behaviors:
---   1. incomingCalls nodes: if the caller's kind is NOT in this set, it's marked
---      as leaf (unexpandable) since non-containers can't have their own callers
---   2. references fallback: only references located INSIDE a symbol with one of
---      these kinds become tree nodes (references in module scope are skipped)
---@type table<integer, boolean>
local container_kinds = {
  [5] = true,   -- Class
  [6] = true,   -- Method
  [9] = true,   -- Constructor
  [12] = true,  -- Function
}

--------------------------------------------------------------------------
-- Node construction
--------------------------------------------------------------------------

--- Build a tree node from a CallHierarchyItem and its call site range.
--- Called when processing callHierarchy/incomingCalls results.
---@param call_from any CallHierarchyItem — the function that contains the call
---@param call_range lsp.Range — where the call expression is in the caller
---@return table node tree node with position and metadata
local function make_call_node(call_from, call_range)
  -- call_range.start = position of the actual call expression
  local lnum, col = lsp.to_vim_pos(call_range.start)
  -- selectionRange.start = position of the function name (for prepareCallHierarchy)
  local def_lnum, def_col = lsp.to_vim_pos(call_from.selectionRange.start)
  -- Non-container symbols (variables, properties) can't have their own callers
  local is_leaf = not container_kinds[call_from.kind]
  return {
    name = call_from.name,        -- display name of the calling function
    item = call_from,             -- original CallHierarchyItem (for direct reuse)
    uri = call_from.uri,          -- file URI where the caller is defined
    def_lnum = def_lnum,          -- definition line (1-indexed, for prepareCallHierarchy)
    def_col = def_col,            -- definition column (1-indexed, for prepareCallHierarchy)
    filename = vim.uri_to_fname(call_from.uri),  -- filesystem path (for display)
    lnum = lnum,                  -- call site line (1-indexed, for jump-to)
    col = col,                    -- call site column (1-indexed, for jump-to)
    is_leaf = is_leaf,            -- whether this node can be further expanded
    is_ref = false,               -- this is a call-hierarchy node, not a reference node
  }
end

--- Build a tree node from a reference location and its enclosing symbol.
--- Called when processing textDocument/references fallback results.
---@param ref_uri string file URI where the reference was found
---@param ref_pos lsp.Position position of the reference (0-indexed)
---@param sym any DocumentSymbol — the smallest enclosing container symbol
---@return table node tree node with position and metadata
local function make_ref_node(ref_uri, ref_pos, sym)
  -- ref_pos = position of the reference itself (call site)
  local lnum, col = lsp.to_vim_pos(ref_pos)
  -- selectionRange or range = symbol name position (for prepareCallHierarchy)
  local sel = sym.selectionRange or sym.range
  local def_lnum, def_col = lsp.to_vim_pos(sel.start)
  return {
    name = sym.name,              -- display name of the enclosing function
    item = nil,                   -- no CallHierarchyItem (reference-based node)
    uri = ref_uri,                -- file URI of the reference
    def_lnum = def_lnum,          -- enclosing symbol definition line (for expansion)
    def_col = def_col,            -- enclosing symbol definition column (for expansion)
    filename = vim.uri_to_fname(ref_uri),  -- filesystem path (for display)
    lnum = lnum,                  -- reference line (1-indexed, for jump-to)
    col = col,                    -- reference column (1-indexed, for jump-to)
    is_leaf = false,              -- reference nodes are always expandable
    is_ref = true,                -- this is a reference node (shown with ref_prefix icon)
  }
end

--------------------------------------------------------------------------
-- Data fetching (runs inside coroutine via lsp.start_request)
--------------------------------------------------------------------------

--- Try to get incoming calls for a CallHierarchyItem.
--- Returns nil if the item is nil, server errors, or no results.
---@param item any? CallHierarchyItem (from prepareCallHierarchy)
---@param req table request context from lsp.start_request
---@return table[]? children array of call nodes, or nil if no results
local function try_incoming_calls(item, req)
  if not item then return nil end
  -- Ensure the file is loaded so the server can process the request
  local target_bufnr = req.ensure_buf_attached(item.uri)
  -- Request incoming calls from the LSP server
  local err, result = req.request(target_bufnr, "callHierarchy/incomingCalls", {
    item = item,
  })
  if err or not result then return nil end
  -- Each incoming call can have multiple fromRanges (same function calls target N times)
  local children = {}
  for _, call in ipairs(result) do
    for _, rng in ipairs(call.fromRanges) do
      table.insert(children, make_call_node(call.from, rng))
    end
  end
  -- Return nil (not empty table) to signal "no results" for fallback logic
  return #children > 0 and children or nil
end

--- Execute a textDocument/references request at a given position.
---@param target_bufnr integer buffer number of the target file
---@param uri string file URI for the request params
---@param lnum integer 1-indexed line number
---@param col integer 1-indexed column number
---@param req table request context from lsp.start_request
---@return any[]? result array of Location objects, or nil on error
local function do_references_request(target_bufnr, uri, lnum, col, req)
  local err, result = req.request(target_bufnr, "textDocument/references", {
    textDocument = { uri = uri },
    position = lsp.to_lsp_pos(lnum, col),
    context = { includeDeclaration = false },  -- exclude the definition itself
  })
  if err or not result then return nil end
  return result
end

--- Fallback: find references and resolve each to its enclosing container symbol.
--- For each reference location:
---   1. Get documentSymbol for the file (cached)
---   2. Find the smallest enclosing symbol matching container_kinds
---   3. Create a ref node if a valid container is found
--- References in module scope (no enclosing container) are silently skipped.
---@param uri string file URI of the symbol to find references for
---@param lnum integer 1-indexed line of the symbol
---@param col integer 1-indexed column of the symbol
---@param req table request context from lsp.start_request
---@return table[] children array of ref nodes (may be empty)
local function try_references(uri, lnum, col, req)
  -- Ensure file is loaded and request references
  local target_bufnr = req.ensure_buf_attached(uri)
  local result = do_references_request(target_bufnr, uri, lnum, col, req)
  if not result or #result == 0 then return {} end
  local children = {}
  for _, location in ipairs(result) do
    local ref_uri = location.uri          -- file where reference appears
    local ref_pos = location.range.start  -- position of the reference
    -- Ensure reference file is loaded (needed for documentSymbol request)
    req.ensure_buf_attached(ref_uri)
    -- Get document symbols for the file (cached across multiple refs in same file)
    local symbols = lsp.get_doc_symbols(ref_uri, req)
    -- Convert to Neovim coordinates for find_enclosing
    local ref_lnum, ref_col = lsp.to_vim_pos(ref_pos)
    -- Find the smallest enclosing container (function/method/class/constructor)
    local sym = lsp.find_enclosing(symbols, ref_lnum, ref_col, container_kinds)
    if sym then
      table.insert(children, make_ref_node(ref_uri, ref_pos, sym))
    end
    -- If sym is nil, reference is in module scope — skip it
  end
  return children
end

--- Expand a node: try incomingCalls first, fall back to references.
--- Called by the TreeDataProvider's get_children when a node is expanded.
---
--- Strategy:
---   1. Re-prepare CallHierarchyItem at the node's definition position
---      (needed because some servers don't return full data in incomingCalls)
---   2. Try incomingCalls — if results, return them
---   3. Otherwise fall back to references
---
---@param node table tree node to expand (has uri, def_lnum, def_col)
---@param req table request context from lsp.start_request
---@return table[]? children array of child nodes, or nil/empty
local function expand_node(node, req)
  -- Re-prepare at definition position (required for some servers)
  local item = lsp.prepare_call_hierarchy(node.uri, node.def_lnum, node.def_col, req)
  -- Try primary method: callHierarchy/incomingCalls
  local children = try_incoming_calls(item, req)
  if children then return children end
  -- Fallback: textDocument/references with enclosing symbol resolution
  return try_references(node.uri, node.def_lnum, node.def_col, req)
end

--------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------

--- Open the incoming call hierarchy panel for the symbol under cursor.
--- Creates a treeview with viewId="call_hierarchy" (singleton — replaces existing).
--- The root node is the symbol at cursor; expanding shows its callers.
local function open_call_hierarchy()
  local bufnr = vim.api.nvim_get_current_buf()        -- source code buffer
  local source_win = vim.api.nvim_get_current_win()    -- window to jump back to on select
  local timeout = vim.g.call_hierarchy_timeout         -- operation timeout
  local icons = vim.g.call_hierarchy_icons             -- icon configuration

  -- Start async LSP operation. req.source captures cursor position automatically.
  -- The root fetch happens BEFORE creating the treeview — panel only shows on success.
  lsp.start_request(bufnr, "textDocument/prepareCallHierarchy", timeout, function(req)
    -- Prepare CallHierarchyItem at cursor position
    local item = lsp.prepare_call_hierarchy(req.source.uri, req.source.lnum, req.source.col, req)
    if not item then
      vim.notify("[call_hierarchy] No call hierarchy item at cursor", vim.log.levels.WARN)
      return
    end

    -- Build root node from the prepared item
    local def_lnum, def_col = lsp.to_vim_pos(item.selectionRange.start)
    local root_nodes = { {
      name = item.name,
      item = item,
      uri = item.uri,
      def_lnum = def_lnum,
      def_col = def_col,
      filename = vim.uri_to_fname(item.uri),
      lnum = def_lnum,   -- root node: jump-to position = definition position
      col = def_col,
      is_leaf = false,    -- root is always expandable
      is_ref = false,     -- root is always a call node
    } }

    --- TreeDataProvider implementation.
    --- Roots are pre-fetched (synchronous callback), children are async via LSP.
    local provider = {
      --- Get children for an element. nil = return roots.
      ---@param element any? nil for roots, node for children
      ---@param callback fun(children: any[]) called with results
      get_children = function(element, callback)
        if not element then
          -- Root level: return pre-fetched root nodes immediately
          callback(root_nodes)
          return
        end
        if element.is_leaf then
          -- Leaf nodes have no children
          callback({})
          return
        end
        -- Expand non-leaf: start a new LSP request chain
        local client = lsp.start_request(bufnr, "textDocument/prepareCallHierarchy", timeout, function(r)
          callback(expand_node(element, r) or {})
        end, function(err)
          vim.notify("[call_hierarchy] " .. err, vim.log.levels.WARN)
          callback({})  -- return empty on error so tree doesn't hang
        end)
        if not client then
          vim.notify("[call_hierarchy:get_children] no client found for buffer " .. bufnr, vim.log.levels.WARN)
          callback({})
        end
      end,

      --- Convert a node to a TreeItem for display.
      ---@param element table tree node
      ---@return TreeItem
      get_tree_item = function(element)
        -- Prefix reference nodes with ref_prefix icon to distinguish from call nodes
        local ref_mark = element.is_ref and (icons.ref_prefix .. " ") or ""
        -- Show filename:line as description
        local loc = vim.fn.fnamemodify(element.filename, ":t") .. ":" .. element.lnum
        return {
          label = ref_mark .. element.name,
          collapsible = not element.is_leaf,
          description = loc,
        }
      end,
    }

    -- Create and show the treeview panel
    local tree = treeview.create({
      viewId = "call_hierarchy",   -- singleton: replaces any existing call hierarchy panel
      title = "Incoming Calls",
      provider = provider,
      on_select = function(element)
        -- Jump to the call site in the source window (not the tree window)
        goto_loc.jump_to(source_win, {
          filename = element.filename,
          lnum = element.lnum,
          col = element.col,
        })
      end,
      expand_level = 1,            -- auto-expand root to show first-level callers
      width = vim.g.call_hierarchy_width,
      position = "right",
      keys = vim.g.call_hierarchy_keys,
      icons = {
        collapsed = icons.collapsed,
        expanded = icons.expanded,
        leaf = icons.leaf,
      },
    })

    tree.show()
  end, function(err)
    -- Error handler for the root LSP operation
    if err:find("timeout") then
      vim.notify("[call_hierarchy] LSP request timed out", vim.log.levels.WARN)
    else
      vim.notify("[call_hierarchy] " .. err, vim.log.levels.ERROR)
    end
  end)
end

return { open = open_call_hierarchy }
