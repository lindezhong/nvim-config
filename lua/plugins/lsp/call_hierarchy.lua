-- call_hierarchy.lua: LSP call hierarchy viewer (incoming + outgoing).
--
-- Displays a tree of callers (incoming) or callees (outgoing) for the
-- symbol under cursor.
--
-- Incoming strategy:
--   1. Primary: callHierarchy/incomingCalls with original item first;
--      re-prepare only on error (jdtls re-prepare can return wrong overload)
--   2. Fallback: textDocument/references when incomingCalls fails, is unsupported, or empty
--      (enclosing container via documentSymbol; root-level refs as leaves; self excluded)
--   If prepareCallHierarchy fails, builds a references-only root from cursor.
--
-- Outgoing strategy:
--   1. callHierarchy/outgoingCalls only (no fallback needed)
--
-- Architecture:
--   - UI: delegated entirely to treeview.lua (tree rendering, panel, keys)
--   - LSP: delegated to lsp.lua (coroutine requests, coordinate conversion)
--   - This file: configuration, TreeDataProvider implementation, node construction

local lsp = require("plugins.lsp.lsp")
local treeview = require("widgets.treeview")
local goto_loc = require("plugins.lsp.goto")

--------------------------------------------------------------------------
-- Configuration (user-overridable via vim.g.*)
--------------------------------------------------------------------------

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

--- SymbolKind values that represent scope-creating containers.
--- Controls two behaviors:
---   1. Nodes with kind NOT in this set are marked as leaf (unexpandable)
---   2. References fallback: only references inside these kinds become nodes
---@type table<integer, boolean>
local container_kinds = {
  [5] = true,   -- Class
  [6] = true,   -- Method
  [9] = true,   -- Constructor
  [10] = true,  -- Enum
  [11] = true,  -- Interface
  [12] = true,  -- Function
  [23] = true,  -- Struct
}

--- Start an LSP request, selecting the best client for call hierarchy operations.
--- Client selection only: prefers a call-hierarchy-capable client, falls back to a
--- references-capable client (e.g., lua_ls). Request-level fallback (incomingCalls
--- empty/failed → references) is handled inside expand_incoming, not here.
local function start_lsp_request(bufnr, timeout, fn, on_error)
  local client = lsp.start_request(bufnr, "textDocument/prepareCallHierarchy", timeout, fn, on_error)
  if not client then
    client = lsp.start_request(bufnr, "textDocument/references", timeout, fn, on_error)
  end
  return client
end

--------------------------------------------------------------------------
-- Node construction (shared by both directions)
--------------------------------------------------------------------------

--- Build a tree node from a CallHierarchyItem and a call site range.
--- For incoming: item = call.from (the caller), call_range = where call happens in caller
--- For outgoing: item = call.to (the callee), call_range = where call happens in current fn
---@param item any CallHierarchyItem (the caller for incoming, the callee for outgoing)
---@param call_range lsp.Range where the call expression is
---@param call_uri? string file URI where call_range lives (only needed for outgoing,
---   where fromRanges is in the queried item's file, not in call.to's file)
---@return table node tree node with position and metadata
local function make_call_node(item, call_range, call_uri)
  -- call_range.start = position of the actual call expression
  local lnum, col = lsp.to_vim_pos(call_range.start)
  -- selectionRange.start = symbol name position (may be inaccurate for some servers;
  -- expand_incoming corrects via documentSymbol before references fallback)
  local def_lnum, def_col = lsp.to_vim_pos(item.selectionRange.start)
  -- Non-container symbols (variables, properties) can't be expanded further
  local is_leaf = not container_kinds[item.kind]
  -- For incoming: call site is in the caller's file (item.uri)
  -- For outgoing: call site is in the queried item's file (call_uri), not call.to's file
  local jump_uri = call_uri or item.uri
  return {
    name = item.name,             -- display name of the function
    item = item,                  -- original CallHierarchyItem (fallback when re-prepare fails)
    uri = item.uri,               -- file URI of this symbol (for expansion via prepareCallHierarchy)
    def_lnum = def_lnum,          -- definition line (1-indexed, for prepareCallHierarchy)
    def_col = def_col,            -- definition column (1-indexed, for prepareCallHierarchy)
    filename = vim.uri_to_fname(jump_uri),  -- file path for jump-to (may differ from uri for outgoing)
    lnum = lnum,                  -- call site line (1-indexed, for jump-to)
    col = col,                    -- call site column (1-indexed, for jump-to)
    is_leaf = is_leaf,            -- whether this node can be further expanded
    is_ref = false,               -- this is a call-hierarchy node, not a reference node
  }
end

--- Build a tree node from a reference location and its enclosing symbol.
--- (Used only by incoming calls fallback.)
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
    filename = vim.uri_to_fname(ref_uri),  -- file path (for jump-to)
    lnum = lnum,                  -- reference line (1-indexed, for jump-to)
    col = col,                    -- reference column (1-indexed, for jump-to)
    is_leaf = not container_kinds[sym.kind],  -- only callable containers are expandable
    is_ref = true,                -- this is a reference node (shown with ref_prefix icon)
  }
end

--------------------------------------------------------------------------
-- Incoming calls: data fetching
--------------------------------------------------------------------------

--- Try to get incoming calls for a CallHierarchyItem.
--- Returns nil if the item is nil, server errors, or no results.
---@param item any? CallHierarchyItem (from prepareCallHierarchy)
---@param req table request context from lsp.start_request
---@return table[]? children array of call nodes; {} = no callers (definitive), nil = error
local function try_incoming_calls(item, req)
  if not item then return nil end
  local target_bufnr = req.ensure_buf_attached(item.uri)
  local err, result = req.request(target_bufnr, "callHierarchy/incomingCalls", {
    item = item,
  })
  if err or not result then return nil end
  local children = {}
  for _, call in ipairs(result) do
    for _, rng in ipairs(call.fromRanges) do
      table.insert(children, make_call_node(call.from, rng))
    end
  end
  return children
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
---   3. Create a ref node; root-level references become leaf nodes with file name
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
    local sym = lsp.find_enclosing(symbols, ref_lnum, ref_col, container_kinds)
    if sym then
      table.insert(children, make_ref_node(ref_uri, ref_pos, sym))
    else
      local fname = vim.uri_to_fname(ref_uri)
      table.insert(children, {
        name = vim.fn.fnamemodify(fname, ":t"),
        item = nil,
        uri = ref_uri,
        def_lnum = ref_lnum,
        def_col = ref_col,
        filename = fname,
        lnum = ref_lnum,
        col = ref_col,
        is_leaf = true,
        is_ref = true,
      })
    end
  end
  return children
end

--- Expand a node for incoming direction: incomingCalls first, references fallback.
--- Called by the TreeDataProvider's get_children when a node is expanded.
---
--- Strategy:
---   1. Try incomingCalls with original item (jdtls: re-prepare can return wrong item)
---   2. On error (nil): re-prepare and retry (tsserver: call.from may be incomplete)
---   3. On empty or all failed: fall back to references
---
---@param node table tree node to expand (has uri, def_lnum, def_col)
---@param req table request context from lsp.start_request
---@return table[]? children array of child nodes, or nil/empty
local function expand_incoming(node, req)
  -- try_incoming_calls returns {} = empty (definitive), nil = error.
  -- Only re-prepare on error; empty skips re-prepare to avoid jdtls wrong-item issue.
  local children = try_incoming_calls(node.item, req)
  if children == nil then
    local item = lsp.prepare_call_hierarchy(node.uri, node.def_lnum, node.def_col, req)
    children = try_incoming_calls(item, req)
  end
  if children and #children > 0 then return children end
  -- call.from.selectionRange may point to call site instead of method name (jdtls).
  -- Use documentSymbol to find the correct enclosing symbol position.
  -- Only for call-hierarchy nodes (node.item); synthetic roots and ref nodes already
  -- have correct def_lnum/def_col from cursor or documentSymbol respectively.
  local ref_lnum, ref_col = node.def_lnum, node.def_col
  if node.item then
    local symbols = lsp.get_doc_symbols(node.uri, req)
    local sym = lsp.find_enclosing(symbols, node.def_lnum, node.def_col, container_kinds)
    if sym then
      local sel = sym.selectionRange or sym.range
      ref_lnum, ref_col = lsp.to_vim_pos(sel.start)
    end
  end
  local refs = try_references(node.uri, ref_lnum, ref_col, req)
  -- Exclude self: references whose enclosing container is the node itself
  return vim.tbl_filter(function(child)
    return not (child.uri == node.uri and child.def_lnum == ref_lnum and child.def_col == ref_col)
  end, refs)
end

--------------------------------------------------------------------------
-- Outgoing calls: data fetching
--------------------------------------------------------------------------

--- Try to get outgoing calls for a CallHierarchyItem.
--- fromRanges are positions in the queried item's file (item.uri), not in call.to's file.
--- Deduplicates by (callee name, start line, start character) since some servers
--- return overlapping ranges for the same call site.
---@param item any? CallHierarchyItem (from prepareCallHierarchy)
---@param req table request context from lsp.start_request
---@return table[]? children array of call nodes; {} = no callees (definitive), nil = error
local function try_outgoing_calls(item, req)
  if not item then return nil end
  local target_bufnr = req.ensure_buf_attached(item.uri)
  local err, result = req.request(target_bufnr, "callHierarchy/outgoingCalls", {
    item = item,
  })
  if err or not result then return nil end
  local children = {}
  local seen = {}  -- dedup key → true; prevents duplicate nodes from overlapping ranges
  for _, call in ipairs(result) do
    for _, rng in ipairs(call.fromRanges) do
      -- Dedup by callee name + exact start position
      local key = call.to.name .. ":" .. rng.start.line .. ":" .. rng.start.character
      if not seen[key] then
        seen[key] = true
        -- Pass item.uri as call_uri: fromRanges are in the queried item's file
        table.insert(children, make_call_node(call.to, rng, item.uri))
      end
    end
  end
  return children
end

--- Expand a node for outgoing direction: outgoingCalls only (no fallback).
---@param node table tree node to expand (has uri, def_lnum, def_col)
---@param req table request context from lsp.start_request
---@return table[]? children array of child nodes, or nil/empty
local function expand_outgoing(node, req)
  -- Original item first, re-prepare only on error (no references fallback for outgoing)
  local children = try_outgoing_calls(node.item, req)
  if children == nil then
    local item = lsp.prepare_call_hierarchy(node.uri, node.def_lnum, node.def_col, req)
    children = try_outgoing_calls(item, req)
  end
  return children
end

--------------------------------------------------------------------------
-- Shared entry point (parameterized by direction)
--------------------------------------------------------------------------

---@alias CallDirection "incoming"|"outgoing"

--- Open the call hierarchy panel for the symbol under cursor.
--- Creates a treeview with direction-specific viewId (can have both open simultaneously).
--- The root node is the symbol at cursor; expanding shows callers or callees.
---@param direction CallDirection "incoming" or "outgoing"
local function open_call_hierarchy(direction)
  local bufnr = vim.api.nvim_get_current_buf()        -- source code buffer
  local source_win = vim.api.nvim_get_current_win()    -- window to jump back to on select
  local timeout = vim.g.call_hierarchy_timeout         -- operation timeout
  local icons = vim.g.call_hierarchy_icons             -- icon configuration
  local cword = vim.fn.expand("<cword>")               -- capture before async

  -- Select expand function and UI labels based on direction
  local expand_fn = direction == "outgoing" and expand_outgoing or expand_incoming
  local view_id = "call_hierarchy_" .. direction  -- separate viewId per direction
  local title = direction == "outgoing" and "Outgoing Calls" or "Incoming Calls"

  -- Start async LSP operation. req.source captures cursor position automatically.
  -- The root fetch happens BEFORE creating the treeview — panel only shows on success.
  start_lsp_request(bufnr, timeout, function(req)
    local item = lsp.prepare_call_hierarchy(req.source.uri, req.source.lnum, req.source.col, req)
    if not item and direction == "outgoing" then
      vim.notify("[call_hierarchy] No call hierarchy item at cursor", vim.log.levels.WARN)
      return
    end

    local root_nodes
    if item then
      local def_lnum, def_col = lsp.to_vim_pos(item.selectionRange.start)
      root_nodes = { {
        name = item.name,
        item = item,
        uri = item.uri,
        def_lnum = def_lnum,
        def_col = def_col,
        filename = vim.uri_to_fname(item.uri),
        lnum = def_lnum,
        col = def_col,
        is_leaf = false,
        is_ref = false,
      } }
    else
      root_nodes = { {
        name = cword,
        item = nil,
        uri = req.source.uri,
        def_lnum = req.source.lnum,
        def_col = req.source.col,
        filename = vim.uri_to_fname(req.source.uri),
        lnum = req.source.lnum,
        col = req.source.col,
        is_leaf = false,
        is_ref = false,
      } }
    end

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
        -- Expand non-leaf: start a new LSP request chain with direction-specific logic
        local client = start_lsp_request(bufnr, timeout, function(r)
          callback(expand_fn(element, r) or {})
        end, function(err)
          vim.notify("[call_hierarchy] " .. err, vim.log.levels.WARN)
          callback({})  -- return empty on error so tree doesn't hang
        end)
        if not client then
          vim.notify("[call_hierarchy] no client found", vim.log.levels.WARN)
          callback({})
        end
      end,

      --- Convert a node to a TreeItem for display.
      ---@param element table tree node
      ---@return TreeItem display node for the element
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
      viewId = view_id,              -- direction-specific (incoming/outgoing can coexist)
      title = title,
      provider = provider,
      on_select = function(element)
        -- Jump to the call site in the source window (not the tree window)
        goto_loc.jump_to(source_win, {
          filename = element.filename,
          lnum = element.lnum,
          col = element.col,
        })
      end,
      expand_level = 1,              -- auto-expand root to show first-level results
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

return {
  incoming = function() open_call_hierarchy("incoming") end,
  outgoing = function() open_call_hierarchy("outgoing") end,
}
