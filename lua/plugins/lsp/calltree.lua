-- Calltree: LSP incoming call hierarchy viewer with tree-style expansion.
-- Uses callHierarchy/incomingCalls as primary method. When incomingCalls
-- returns 0 results, falls back to textDocument/references to capture

-- Configuration: set these globals before this file loads to override defaults.
-- vim.g.calltree_width: number of columns for the tree panel (default: 40)
-- vim.g.calltree_timeout: LSP operation timeout in ms (default: 10000)
-- vim.g.calltree_keys: table of keybindings with fields:
--   toggle - expand or collapse a node (default: <Tab>)
--   jump   - jump to the call site in the source file (default: <CR>)
--   close  - close the tree panel (default: q)
-- vim.g.calltree_icons: table of tree node icons with fields:
--   collapsed   - icon for collapsed node (default: +)
--   expanded    - icon for expanded node (default: -)
--   leaf        - icon for leaf node (default: -)
--   ref_prefix  - prefix for nodes found via references fallback (default: *)
vim.g.calltree_width = vim.g.calltree_width or 40
vim.g.calltree_timeout = vim.g.calltree_timeout or 10000
vim.g.calltree_keys = vim.tbl_extend("keep", vim.g.calltree_keys or {}, {
  toggle = "<Tab>",
  jump = "<CR>",
  close = "q",
})
vim.g.calltree_icons = vim.tbl_extend("keep", vim.g.calltree_icons or {}, {
  collapsed = "+",
  expanded = "-",
  leaf = "-",
  ref_prefix = "*",
})

-- SymbolKind values that represent callable containers.
-- Only these kinds are considered valid "callers" in the tree.
-- Controls two behaviors:
--   1. In callHierarchy results: nodes with kind NOT in this set are marked as leaf (unexpandable)
--   2. In references fallback: only references inside symbols with these kinds become tree nodes
-- https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#symbolKind
local container_kinds = {
  -- [1] = true,   -- File
  -- [2] = true,   -- Module
  -- [3] = true,   -- Namespace
  -- [4] = true,   -- Package
  [5] = true,      -- Class
  [6] = true,      -- Method
  -- [7] = true,   -- Property
  -- [8] = true,   -- Field
  [9] = true,      -- Constructor
  -- [10] = true,  -- Enum
  -- [11] = true,  -- Interface
  [12] = true,     -- Function
  -- [13] = true,  -- Variable
  -- [14] = true,  -- Constant
  -- [15] = true,  -- String
  -- [16] = true,  -- Number
  -- [17] = true,  -- Boolean
  -- [18] = true,  -- Array
  -- [19] = true,  -- Object
  -- [20] = true,  -- Key
  -- [21] = true,  -- Null
  -- [22] = true,  -- EnumMember
  -- [23] = true,  -- Struct
  -- [24] = true,  -- Event
  -- [25] = true,  -- Operator
  -- [26] = true,  -- TypeParameter
}

--------------------------------------------------------------------------
-- Utility functions (pure, no closure dependencies)
--------------------------------------------------------------------------

-- Check if a LSP position {line, character} falls within a LSP range.
local function pos_in_range(pos, range)
  if pos.line < range.start.line or pos.line > range["end"].line then
    return false
  end
  if pos.line == range.start.line and pos.character < range.start.character then
    return false
  end
  if pos.line == range["end"].line and pos.character > range["end"].character then
    return false
  end
  return true
end

-- Approximate size of a range in characters (for comparing which range is "smallest").
local function range_size(range)
  local lines = range["end"].line - range.start.line
  local chars = range["end"].character - range.start.character
  return lines * 10000 + chars
end

-- Find the smallest enclosing container symbol for a given position.
-- Handles two documentSymbol response formats:
--   - DocumentSymbol[] (hierarchical, has children) — recursive descent
--   - SymbolInformation[] (flat, has location but no children) — linear scan for smallest range
local function find_enclosing(symbols, pos)
  if not symbols then return nil end
  -- Detect format: if any symbol has children, it's hierarchical (DocumentSymbol[])
  local has_children = false
  for _, sym in ipairs(symbols) do
    if sym.children then has_children = true break end
  end
  if has_children then
    -- Hierarchical format: recurse into children for most specific match
    for _, sym in ipairs(symbols) do
      local range = sym.range or (sym.location and sym.location.range)
      if range and pos_in_range(pos, range) then
        if sym.children then
          local child = find_enclosing(sym.children, pos)
          if child then return child end
        end
        if container_kinds[sym.kind] then
          return sym
        end
      end
    end
  else
    -- Flat format (SymbolInformation[]): find the smallest containing range
    local best = nil
    local best_size = math.huge
    for _, sym in ipairs(symbols) do
      local range = sym.range or (sym.location and sym.location.range)
      if range and pos_in_range(pos, range) and container_kinds[sym.kind] then
        local size = range_size(range)
        if size < best_size then
          best = sym
          best_size = size
        end
      end
    end
    return best
  end
  return nil
end

--------------------------------------------------------------------------
-- Module-level state
--------------------------------------------------------------------------

-- Window/buffer for the tree panel (persists across invocations for reuse)
local active_tree_win = nil
local active_tree_buf = nil

-- Cache documentSymbol results per file URI to avoid repeated requests
-- when multiple references point to the same file during a single expansion.
local doc_symbol_cache = {}

-- Invalidate cache when a file is saved (symbols may have changed).
vim.api.nvim_create_autocmd("BufWritePost", {
  callback = function(ev)
    doc_symbol_cache[vim.uri_from_bufnr(ev.buf)] = nil
  end,
})

--------------------------------------------------------------------------
-- Core logic
--------------------------------------------------------------------------

local function open_calltree()
  local bufnr = vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  -- Find a client that supports callHierarchy for the current buffer
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/prepareCallHierarchy" })
  if #clients == 0 then return end
  local client = clients[1]

  -- Session state for this tree instance
  local tree = {}            -- root node list (always single root)
  local tree_buf, tree_win   -- buffer and window for the tree panel
  local visible_nodes = {}   -- flattened list of currently rendered nodes (index = line number)
  local expanding = false    -- guard: prevent concurrent expand operations
  local deadline             -- absolute timestamp (ms) when current operation should timeout

  -- Forward declaration: coroutine resume function with error handling.
  -- Set by start_async before each async operation. All LSP callbacks route through
  -- this function so that errors (including timeout) are properly caught and reported.
  local resume

  -- Send an async LSP request and yield until response arrives.
  -- Uses a per-operation deadline (shared across all requests in one operation).
  -- Throws error("timeout") if:
  --   1. Deadline already passed before sending the request
  --   2. vim.defer_fn timer fires before server responds (cancels the pending request)
  --   3. Server responds with err="timeout" (shouldn't normally happen)
  -- All coroutine resumes go through `resume` to ensure error handling.
  local function lsp_request(target_bufnr, method, params)
    local remaining = deadline - vim.uv.now()
    if remaining <= 0 then error("timeout") end
    local co = coroutine.running()
    local done = false  -- guards against double-resume (response + timer race)
    local cancel_fn
    -- Send the request; callback fires when server responds
    _, cancel_fn = vim.lsp.buf_request(target_bufnr, method, params, function(err, result)
      if done then return end
      done = true
      vim.schedule(function()
        resume(err, result)
      end)
    end)
    -- Timeout timer: if server doesn't respond within remaining deadline, cancel and resume with error
    vim.defer_fn(function()
      if done then return end
      done = true
      if cancel_fn then cancel_fn() end
      vim.schedule(function()
        resume("timeout", nil)
      end)
    end, remaining)
    -- Yield coroutine; will be resumed by either the LSP callback or the timeout timer
    local err, result = coroutine.yield()
    if err == "timeout" then error("timeout") end
    return err, result
  end

  -- Start an async operation in a coroutine.
  -- Sets up the `resume` function that all LSP callbacks use.
  -- on_error is called if the coroutine throws (including timeout).
  local function start_async(fn, on_error)
    local co = coroutine.create(fn)
    -- Every coroutine.resume goes through this function, so errors are always caught.
    -- Without this, bare coroutine.resume in callbacks would silently swallow errors.
    resume = function(...)
      if coroutine.status(co) == "dead" then return end
      local ok, err = coroutine.resume(co, ...)
      if not ok then
        if on_error then on_error(tostring(err)) end
      end
    end
    resume()  -- initial resume to start the coroutine
  end

  -- Load a file into a buffer and attach the LSP client if needed.
  -- This triggers textDocument/didOpen for the server, which is required by some servers
  -- (notably vtsls) to include the file in their project index before responding to queries.
  local function ensure_buf_attached(uri)
    local fname = vim.uri_to_fname(uri)
    local target_bufnr = require("plugins.lsp.buf").ensure_loaded(fname)
    local attached = false
    for _, c in ipairs(vim.lsp.get_clients({ bufnr = target_bufnr })) do
      if c.id == client.id then
        attached = true
        break
      end
    end
    if not attached then
      vim.lsp.buf_attach_client(target_bufnr, client.id)
    end
    return target_bufnr
  end

  -- Get documentSymbol results for a file (cached per session).
  -- Used by try_references to find the enclosing function/method for each reference location.
  local function get_doc_symbols(uri)
    if doc_symbol_cache[uri] then return doc_symbol_cache[uri] end
    local target_bufnr = ensure_buf_attached(uri)
    local err, result = lsp_request(target_bufnr, "textDocument/documentSymbol", {
      textDocument = { uri = uri },
    })
    if not err and result then
      doc_symbol_cache[uri] = result
      return result
    end
    vim.notify("[calltree] documentSymbol unavailable for " .. vim.uri_to_fname(uri), vim.log.levels.WARN)
    return nil
  end

  -- Get a complete CallHierarchyItem via prepareCallHierarchy.
  -- Some servers (vtsls) don't include the `data` field in call.from for cross-file items,
  -- so we need to re-prepare to get the complete item before querying incomingCalls.
  local function prepare_item(uri, position)
    local target_bufnr = ensure_buf_attached(uri)
    local err, result = lsp_request(target_bufnr, "textDocument/prepareCallHierarchy", {
      textDocument = { uri = uri },
      position = position,
    })
    if not err and result and not vim.tbl_isempty(result) then
      return result[1]
    end
    return nil
  end

  -- Primary expansion method: query callHierarchy/incomingCalls.
  -- Returns a list of child nodes, or nil if no results.
  -- Each call site in fromRanges becomes a separate node (same caller can appear multiple times).
  -- Nodes with kind not in container_kinds are marked as leaf (children = {}).
  local function try_incoming_calls(item)
    if not item then return nil end
    local target_bufnr = ensure_buf_attached(item.uri)
    local err, result = lsp_request(target_bufnr, "callHierarchy/incomingCalls", {
      item = item,
    })
    if err or not result then return nil end
    local children = {}
    for _, call in ipairs(result) do
      local is_leaf = not container_kinds[call.from.kind]
      for _, rng in ipairs(call.fromRanges) do
        table.insert(children, {
          name = call.from.name,
          item = call.from,           -- CallHierarchyItem for further expansion
          uri = call.from.uri,
          def_start = call.from.selectionRange.start,
          filename = vim.uri_to_fname(call.from.uri),
          lnum = rng.start.line + 1,  -- call site line (1-indexed for vim)
          col = rng.start.character + 1,
          expanded = false,
          children = is_leaf and {} or nil,  -- {} = leaf (no expand), nil = expandable
          is_ref = false,
        })
      end
    end
    return children
  end

  -- Fallback expansion: query textDocument/references and resolve enclosing function.
  -- Used when incomingCalls returns 0 results (e.g., JSX <Component /> usage).
  -- For each reference, finds the enclosing container symbol via documentSymbol.
  -- References not inside a container_kinds symbol are filtered out (e.g., imports, top-level).
  -- Nodes from this path are marked with is_ref=true for display with ref_prefix icon.
  local function try_references(uri, position)
    local target_bufnr = ensure_buf_attached(uri)
    local err, result = lsp_request(target_bufnr, "textDocument/references", {
      textDocument = { uri = uri },
      position = position,
      context = { includeDeclaration = false },
    })
    if err or not result then return {} end
    local children = {}
    for _, location in ipairs(result) do
      local ref_uri = location.uri
      local ref_pos = location.range.start
      ensure_buf_attached(ref_uri)
      local sym = find_enclosing(get_doc_symbols(ref_uri), ref_pos)
      if sym then
        local sel = sym.selectionRange or sym.range
        table.insert(children, {
          name = sym.name,
          item = nil,                   -- no CallHierarchyItem (came from references)
          uri = ref_uri,
          def_start = sel.start,        -- enclosing symbol's definition position
          filename = vim.uri_to_fname(ref_uri),
          lnum = ref_pos.line + 1,      -- reference site line (where the usage is)
          col = ref_pos.character + 1,
          expanded = false,
          children = nil,               -- nil = expandable (will use prepare_item on expand)
          is_ref = true,                -- flag for ref_prefix icon display
        })
      end
    end
    return children
  end

  -- Expand a node: try callHierarchy/incomingCalls first (standard LSP call hierarchy).
  -- If it returns 0 results, fall back to textDocument/references to capture
  -- usage patterns not covered by call hierarchy (JSX components, higher-order functions, etc.).
  local function expand_node(node)
    local item = prepare_item(node.uri, node.def_start)
    local children = try_incoming_calls(item)
    if children and #children > 0 then
      node.children = children
    else
      node.children = try_references(node.uri, node.def_start)
    end
  end

  --------------------------------------------------------------------------
  -- UI: rendering and interaction
  --------------------------------------------------------------------------

  -- Render the tree into the buffer as indented text lines.
  -- Builds visible_nodes[] in parallel so line number → node lookup is O(1).
  local function render()
    local lines = {}
    visible_nodes = {}
    local icons = vim.g.calltree_icons
    local function walk(node_list, depth)
      for _, node in ipairs(node_list) do
        local indent = string.rep("  ", depth)
        -- Icon logic:
        --   has children & expanded → expanded icon (-)
        --   has children & collapsed → collapsed icon (+)
        --   children == nil (never expanded) → collapsed icon (+) (expandable)
        --   children == {} (leaf) → leaf icon (-)
        local icon
        if node.children and #node.children > 0 then
          icon = node.expanded and icons.expanded or icons.collapsed
        elseif node.children == nil then
          icon = icons.collapsed
        else
          icon = icons.leaf
        end
        local ref_mark = node.is_ref and (icons.ref_prefix .. " ") or ""
        local loc = vim.fn.fnamemodify(node.filename, ":t") .. ":" .. node.lnum
        table.insert(lines, indent .. icon .. " " .. ref_mark .. node.name .. " (" .. loc .. ")")
        table.insert(visible_nodes, node)
        if node.expanded and node.children then
          walk(node.children, depth + 1)
        end
      end
    end
    walk(tree, 0)
    vim.bo[tree_buf].modifiable = true
    vim.api.nvim_buf_set_lines(tree_buf, 0, -1, false, lines)
    vim.bo[tree_buf].modifiable = false
  end

  local function get_node_at_cursor()
    local row = vim.api.nvim_win_get_cursor(tree_win)[1]
    return visible_nodes[row]
  end

  -- Format timeout error message with current timeout value and config hint.
  local function timeout_msg()
    local timeout_sec = vim.g.calltree_timeout / 1000
    return "[calltree] LSP request timed out after " .. timeout_sec
      .. "s, server may still be loading. Set vim.g.calltree_timeout to adjust (ms)"
  end

  -- Handle Tab key: toggle expanded state or trigger async expansion.
  -- Uses `expanding` flag to prevent concurrent expansions (only one at a time).
  local function toggle_or_expand()
    local node = get_node_at_cursor()
    if not node then return end
    if node.expanded then
      -- Already expanded → collapse (just hide children, don't discard them)
      node.expanded = false
      render()
    elseif node.children then
      -- Has children from previous expansion → re-expand (show them again)
      node.expanded = true
      render()
    else
      -- Never expanded → fetch children from LSP (async)
      if expanding then return end
      expanding = true
      start_async(function()
        deadline = vim.uv.now() + vim.g.calltree_timeout
        expand_node(node)
        node.expanded = true
        render()
        expanding = false
      end, function(err)
        expanding = false  -- always reset so user can retry
        if err:find("timeout") then
          vim.notify(timeout_msg(), vim.log.levels.WARN)
        else
          vim.notify("[calltree] " .. err, vim.log.levels.ERROR)
        end
      end)
    end
  end

  -- Jump to the call site in the source file (CR key).
  local function jump_to_node()
    local node = get_node_at_cursor()
    if not node then return end
    if vim.api.nvim_win_is_valid(source_win) then
      vim.api.nvim_set_current_win(source_win)
    else
      vim.cmd("wincmd p")
    end
    vim.cmd("drop " .. vim.fn.fnameescape(node.filename))
    vim.api.nvim_win_set_cursor(0, { node.lnum, node.col - 1 })
  end

  -- Close the tree panel and clear module state.
  local function close_tree()
    if tree_win and vim.api.nvim_win_is_valid(tree_win) then
      vim.cmd("close")
      vim.cmd("mode")  -- force terminal redraw after closing vsplit
    end
    active_tree_win = nil
    active_tree_buf = nil
  end

  -- Create the scratch buffer for tree rendering.
  local function create_tree_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"  -- auto-cleanup when hidden
    vim.bo[buf].filetype = "calltree"
    return buf
  end

  -- Open (or reuse) the tree panel on the right side.
  -- Reuses existing tree window if still valid (repeated invocations replace content).
  local function open_panel()
    tree_buf = create_tree_buf()
    if active_tree_win and vim.api.nvim_win_is_valid(active_tree_win) then
      -- Reuse existing window, just swap the buffer
      tree_win = active_tree_win
      vim.api.nvim_win_set_buf(tree_win, tree_buf)
    else
      -- Create new vsplit on the right
      vim.cmd("botright " .. vim.g.calltree_width .. "vsplit")
      tree_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(tree_win, tree_buf)
      vim.wo[tree_win].number = false
      vim.wo[tree_win].relativenumber = false
      vim.wo[tree_win].signcolumn = "no"
      vim.wo[tree_win].wrap = false
    end
    vim.api.nvim_set_current_win(tree_win)
    active_tree_win = tree_win
    active_tree_buf = tree_buf

    -- Set buffer-local keymaps for tree interaction
    local keys = vim.g.calltree_keys
    local opts = { buffer = tree_buf, nowait = true }
    -- Toggle node: expand to fetch callers, or collapse to hide children
    vim.keymap.set("n", keys.toggle, toggle_or_expand, opts)
    -- Jump to call site: open the source file at the exact call location
    vim.keymap.set("n", keys.jump, jump_to_node, opts)
    -- Close tree panel: close the calltree window and clean up state
    vim.keymap.set("n", keys.close, close_tree, opts)
  end

  --------------------------------------------------------------------------
  -- Entry: async prepare, expand, and open panel
  --------------------------------------------------------------------------

  -- Capture cursor position synchronously before going async
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  local uri = vim.uri_from_bufnr(bufnr)

  -- Start async operation: prepare the root item, expand it, then show the panel.
  -- If prepareCallHierarchy returns nil, cursor is not on a valid symbol.
  -- If any LSP request exceeds the deadline, the whole operation aborts with timeout.
  start_async(function()
    deadline = vim.uv.now() + vim.g.calltree_timeout
    local item = prepare_item(uri, params.position)
    if not item then
      vim.notify("[calltree] No call hierarchy item found at cursor position", vim.log.levels.WARN)
      return
    end
    local root = {
      name = item.name,
      item = item,
      uri = item.uri,
      def_start = item.selectionRange.start,
      filename = vim.uri_to_fname(item.uri),
      lnum = item.selectionRange.start.line + 1,
      col = item.selectionRange.start.character + 1,
      expanded = false,
      children = nil,
      is_ref = false,
    }
    tree = { root }
    expand_node(root)
    root.expanded = true
    open_panel()
    render()
  end, function(err)
    if err:find("timeout") then
      vim.notify(timeout_msg(), vim.log.levels.WARN)
    else
      vim.notify("[calltree] " .. err, vim.log.levels.ERROR)
    end
  end)
end

return { open = open_calltree }
