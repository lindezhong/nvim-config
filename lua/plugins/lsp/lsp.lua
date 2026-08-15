-- lsp.lua: Unified LSP operations entry point.
--
-- All LSP interactions in the project go through this module.
-- Provides a coroutine-based request mechanism for multi-step LSP operations
-- (e.g., prepareCallHierarchy → incomingCalls → references chain).
--
-- Design principles:
--   - Public interfaces use Neovim coordinates (1-indexed line and column)
--   - Client selection handled internally (picks first client supporting the method)
--   - Cross-file buffer loading and client attachment handled internally
--   - Coroutine-based request with shared deadline timeout for operation chains
--   - Single client per operation (not broadcast) for deterministic behavior

local buf_utils = require("plugins.lsp.buf")

local M = {}

--------------------------------------------------------------------------
-- Simple passthrough (unified entry point for future extension)
--------------------------------------------------------------------------

M.hover = vim.lsp.buf.hover                     --- Show hover documentation
M.rename = vim.lsp.buf.rename                   --- Rename symbol across project
M.code_action = vim.lsp.buf.code_action         --- Show available code actions
M.format = vim.lsp.buf.format                   --- Format buffer or selection
M.type_definition = vim.lsp.buf.type_definition --- Jump to type definition
M.implementation = vim.lsp.buf.implementation   --- Jump to implementation
M.workspace_symbol = vim.lsp.buf.workspace_symbol --- Search workspace symbols
M.selection_range = vim.lsp.buf.selection_range --- Expand selection by syntax

--------------------------------------------------------------------------
-- High-level operations (callback-based, single-step)
--------------------------------------------------------------------------

--- Go to definition. Delegates to vim.lsp.buf.definition.
--- Supports on_list callback for handling multiple definition locations.
---@param opts? { on_list?: fun(options: { items: table[] }) }
function M.definition(opts)
  vim.lsp.buf.definition(opts)
end

--- Find references. Delegates to vim.lsp.buf.references.
--- Supports on_list callback for custom display of reference locations.
---@param opts? { on_list?: fun(options: { items: table[] }) }
function M.references(opts)
  vim.lsp.buf.references(nil, opts)
end

--- Get document symbols. Delegates to vim.lsp.buf.document_symbol.
--- Supports on_list callback for custom display (e.g., outline panel).
---@param opts? table
function M.document_symbol(opts)
  vim.lsp.buf.document_symbol(opts)
end

-- SymbolKind values from LSP 3.17 specification.
-- Reference table for kind_filter usage in find_enclosing.
-- 1=File, 2=Module, 3=Namespace, 4=Package, 5=Class, 6=Method,
-- 7=Property, 8=Field, 9=Constructor, 10=Enum, 11=Interface,
-- 12=Function, 13=Variable, 14=Constant, 15=String, 16=Number,
-- 17=Boolean, 18=Array, 19=Object, 20=Key, 21=Null,
-- 22=EnumMember, 23=Struct, 24=Event, 25=Operator, 26=TypeParameter

--------------------------------------------------------------------------
-- Internal helpers
--------------------------------------------------------------------------

--- Cache for documentSymbol results, keyed by file URI.
--- Avoids repeated LSP requests when multiple references point to the same file.
--- Invalidated on BufWritePost (file content changed).
---@type table<string, any[]>
local doc_symbol_cache = {}

-- Invalidate documentSymbol cache when a buffer is saved.
vim.api.nvim_create_autocmd("BufWritePost", {
  callback = function(ev)
    -- Convert buffer number to URI for cache key lookup
    doc_symbol_cache[vim.uri_from_bufnr(ev.buf)] = nil
  end,
})

--- Find the first LSP client attached to a buffer that supports a given method.
---@param bufnr integer buffer number to search clients on
---@param method string LSP method name (e.g., "textDocument/references")
---@return vim.lsp.Client? client first capable client, or nil if none found
local function get_client(bufnr, method)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })
  return clients[1]
end

--- Ensure a file is loaded into a buffer and the given client is attached to it.
--- If the client is not already attached, calls buf_attach_client which sends
--- textDocument/didOpen to the server (required for the server to know about the file).
---@param client vim.lsp.Client the LSP client to attach
---@param uri string file URI (e.g., "file:///path/to/file.ts")
---@return integer bufnr the buffer number of the loaded file
local function do_ensure_buf_attached(client, uri)
  -- Convert URI to filesystem path and load into a buffer
  local fname = vim.uri_to_fname(uri)
  local target_bufnr = buf_utils.ensure_loaded(fname)
  -- Check if client is already attached to this buffer
  local already_attached = false
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = target_bufnr })) do
    if c.id == client.id then
      already_attached = true
      break
    end
  end
  -- Attach client if needed (triggers textDocument/didOpen notification)
  if not already_attached then
    vim.lsp.buf_attach_client(target_bufnr, client.id)
  end
  return target_bufnr
end

--- Convert Neovim 1-indexed position to LSP 0-indexed Position.
---@param lnum integer 1-indexed line number
---@param col integer 1-indexed column number
---@return lsp.Position position {line: integer, character: integer}
local function to_lsp_pos(lnum, col)
  return { line = lnum - 1, character = col - 1 }
end

--- Convert LSP 0-indexed Position to Neovim 1-indexed position.
---@param pos lsp.Position {line: integer, character: integer}
---@return integer lnum 1-indexed line number
---@return integer col 1-indexed column number
local function to_vim_pos(pos)
  return pos.line + 1, pos.character + 1
end

--- Check if a LSP Position falls within a LSP Range (inclusive).
---@param pos lsp.Position {line, character}
---@param range lsp.Range {start: Position, end: Position}
---@return boolean
local function pos_in_range(pos, range)
  -- Before range start
  if pos.line < range.start.line or pos.line > range["end"].line then
    return false
  end
  -- On start line but before start character
  if pos.line == range.start.line and pos.character < range.start.character then
    return false
  end
  -- On end line but after end character
  if pos.line == range["end"].line and pos.character > range["end"].character then
    return false
  end
  return true
end

--- Compute an approximate size score for a range (used to find smallest enclosing).
--- Larger values mean larger ranges. Not exact character count, but sufficient for comparison.
---@param range lsp.Range {start: Position, end: Position}
---@return integer size approximate size score
local function range_size(range)
  local lines = range["end"].line - range.start.line
  local chars = range["end"].character - range.start.character
  return lines * 10000 + chars
end

--- Recursively find the smallest enclosing symbol in a hierarchical DocumentSymbol tree.
--- Descends into children first (deepest match wins), then checks the parent.
---@param symbols any[]? DocumentSymbol[] with children
---@param pos lsp.Position target position
---@param kind_filter? table<integer, boolean> only match symbols with these kinds
---@return any? symbol the smallest enclosing symbol matching the filter, or nil
local function find_enclosing_recursive(symbols, pos, kind_filter)
  if not symbols then return nil end
  for _, sym in ipairs(symbols) do
    -- Get the full range of the symbol (covers entire declaration body)
    local range = sym.range or (sym.location and sym.location.range)
    if range and pos_in_range(pos, range) then
      -- Try children first for a more specific match
      if sym.children then
        local child = find_enclosing_recursive(sym.children, pos, kind_filter)
        if child then return child end
      end
      -- Check this symbol against kind filter
      if not kind_filter or kind_filter[sym.kind] then
        return sym
      end
    end
  end
  return nil
end

--------------------------------------------------------------------------
-- Low-level: coroutine-based async LSP requests
--------------------------------------------------------------------------

--- Start an async LSP operation with a dedicated client and timeout.
---
--- Finds a client supporting `method` on `source_bufnr`, creates a coroutine,
--- and passes a request context table to `fn`. The context provides:
---   req.request(bufnr, method, params) — sends LSP request, yields until response
---   req.ensure_buf_attached(uri) — loads file into buffer + attaches client
---   req.client — the resolved LSP client instance
---   req.deadline — absolute deadline timestamp (vim.uv.now() based)
---   req.source — cursor context captured at call site (Neovim 1-indexed),
---     nil if current buffer ≠ source_bufnr (e.g., called from treeview panel):
---     { bufnr: integer, uri: string, lnum: integer, col: integer }
---
--- The coroutine shares a single deadline across all requests in the operation.
--- If any request exceeds the deadline, error("timeout") propagates to on_error.
---
---@param source_bufnr integer buffer to find client from
---@param method string LSP method name for client capability lookup
---@param timeout_ms integer total operation timeout in milliseconds
---@param fn fun(req: table) coroutine body receiving the request context
---@param on_error? fun(err: string) called if coroutine throws (including timeout)
---@return vim.lsp.Client? client the resolved client, or nil if no capable client found
function M.start_request(source_bufnr, method, timeout_ms, fn, on_error)
  -- Find a client that supports the requested method
  local client = get_client(source_bufnr, method)
  if not client then return nil end

  -- Capture source context at call site (cursor position in Neovim coordinates).
  -- Only meaningful when current buffer matches source_bufnr (e.g., first invocation
  -- from source code window). When called from a treeview panel, source is nil
  -- because the current buffer is the tree buffer, not the source code.
  ---@type {bufnr: integer, uri: string, lnum: integer, col: integer}?
  local source = nil
  if vim.api.nvim_get_current_buf() == source_bufnr then
    local cur = vim.api.nvim_win_get_cursor(0) -- {row: 1-indexed, col: 0-indexed}
    source = {
      bufnr = source_bufnr,
      uri = vim.uri_from_bufnr(source_bufnr),
      lnum = cur[1],        -- 1-indexed line
      col = cur[2] + 1,     -- convert 0-indexed byte offset to 1-indexed column
    }
  end

  -- Forward declaration for coroutine resume function
  local resume
  -- Shared deadline for all requests in this operation chain
  local deadline = vim.uv.now() + timeout_ms

  --- Send a single LSP request and yield the coroutine until the response arrives.
  --- Automatically cancels the request if the deadline is exceeded.
  ---@param target_bufnr integer buffer to associate with the request
  ---@param req_method string LSP method name
  ---@param params table LSP request parameters
  ---@return any? err error from server (nil on success)
  ---@return any? result response payload from server
  local function request(target_bufnr, req_method, params)
    -- Check if deadline already passed before sending
    local remaining = deadline - vim.uv.now()
    if remaining <= 0 then error("timeout") end
    -- Guard against double-resume (response callback vs timeout timer race)
    local done = false
    local request_id
    -- Send request to the LSP server via the client
    local ok, rid = client:request(req_method, params, function(err, result)
      -- Server responded — resume coroutine with the result
      if done then return end
      done = true
      vim.schedule(function()
        resume(err, result)
      end)
    end, target_bufnr)
    -- If request failed to send (client shut down), error immediately
    if not ok then
      error("request failed: " .. req_method)
    end
    request_id = rid
    -- Set up timeout timer to cancel the request if server is too slow
    vim.defer_fn(function()
      if done then return end
      done = true
      -- Cancel the pending request on the server side
      if request_id then client:cancel_request(request_id) end
      -- Resume coroutine with timeout error
      vim.schedule(function()
        resume("timeout", nil)
      end)
    end, remaining)
    -- Yield coroutine — will be resumed by either the response callback or timeout
    local err, result = coroutine.yield()
    -- Propagate timeout as a Lua error (caught by the coroutine error handler)
    if err == "timeout" then error("timeout") end
    return err, result
  end

  -- Build the request context table passed to the coroutine body
  local req = {
    request = request,
    ensure_buf_attached = function(uri)
      return do_ensure_buf_attached(client, uri)
    end,
    client = client,
    deadline = deadline,
    source = source,
  }

  -- Create and start the coroutine
  local co = coroutine.create(function()
    fn(req)
  end)
  -- Resume function: resumes the coroutine and catches errors.
  -- All callbacks (LSP response, timeout timer) route through this
  -- so that errors are consistently reported via on_error.
  resume = function(...)
    -- Don't resume a dead coroutine (already finished or errored)
    if coroutine.status(co) == "dead" then return end
    local ok, err = coroutine.resume(co, ...)
    if not ok then
      -- Coroutine threw an error — report it
      if on_error then on_error(tostring(err)) end
    end
  end
  -- Initial resume to start the coroutine (runs until first yield)
  resume()

  return client
end

--------------------------------------------------------------------------
-- Utility functions (used by call_hierarchy and other multi-step operations)
--------------------------------------------------------------------------

--- Get documentSymbol for a file, with caching.
--- Cache is invalidated on BufWritePost. Results are shared across
--- multiple calls within the same operation (e.g., resolving enclosing
--- symbols for several references in the same file).
---@param uri string file URI
---@param req table request context from start_request
---@return any[]? symbols DocumentSymbol[] or SymbolInformation[], or nil on error
function M.get_doc_symbols(uri, req)
  -- Return cached result if available
  if doc_symbol_cache[uri] then return doc_symbol_cache[uri] end
  -- Ensure file is loaded and client is attached before requesting
  local target_bufnr = req.ensure_buf_attached(uri)
  -- Request document symbols from the server
  local err, result = req.request(target_bufnr, "textDocument/documentSymbol", {
    textDocument = { uri = uri },
  })
  -- Cache successful results for reuse within the same operation
  if not err and result then
    doc_symbol_cache[uri] = result
    return result
  end
  return nil
end

--- Prepare a CallHierarchyItem at a given position in a file.
--- This is required before calling callHierarchy/incomingCalls or outgoingCalls.
--- Some servers don't include full data in incomingCalls results,
--- so re-preparing at the definition position is necessary for further expansion.
---@param uri string target file URI
---@param lnum integer 1-indexed line number of the symbol
---@param col integer 1-indexed column number of the symbol
---@param req table request context from start_request
---@return any? item CallHierarchyItem or nil if no item at position
function M.prepare_call_hierarchy(uri, lnum, col, req)
  -- Ensure file is loaded and client is attached
  local target_bufnr = req.ensure_buf_attached(uri)
  -- Request call hierarchy preparation at the given position
  local err, result = req.request(target_bufnr, "textDocument/prepareCallHierarchy", {
    textDocument = { uri = uri },
    position = to_lsp_pos(lnum, col),
  })
  -- Return the first item (there's typically only one)
  if not err and result and not vim.tbl_isempty(result) then
    return result[1]
  end
  return nil
end

--- Find the smallest enclosing container symbol for a given position.
--- Used by the references fallback to determine which function/method
--- contains a particular reference location.
---
--- Handles two documentSymbol response formats:
---   - DocumentSymbol[] (hierarchical, has children) — recursive descent
---   - SymbolInformation[] (flat, has location) — linear scan for smallest range
---
---@param symbols any[] documentSymbol result (either format)
---@param lnum integer 1-indexed line number
---@param col integer 1-indexed column number
---@param kind_filter? table<integer, boolean> only match these SymbolKind values (nil = all)
---@return any? symbol the smallest enclosing symbol matching the filter, or nil
function M.find_enclosing(symbols, lnum, col, kind_filter)
  if not symbols then return nil end
  -- Convert to LSP position for range comparison
  local pos = to_lsp_pos(lnum, col)
  -- Detect response format: hierarchical (has children) vs flat
  local has_children = false
  for _, sym in ipairs(symbols) do
    if sym.children then has_children = true break end
  end
  -- Hierarchical format: use recursive descent (deepest match wins)
  if has_children then
    return find_enclosing_recursive(symbols, pos, kind_filter)
  end
  -- Flat format (SymbolInformation[]): find smallest containing range
  local best = nil
  local best_size = math.huge
  for _, sym in ipairs(symbols) do
    local range = sym.range or (sym.location and sym.location.range)
    if range and pos_in_range(pos, range) then
      if not kind_filter or kind_filter[sym.kind] then
        local size = range_size(range)
        if size < best_size then
          best = sym
          best_size = size
        end
      end
    end
  end
  return best
end

--- Convert LSP 0-indexed Position to Neovim 1-indexed position (public).
---@param pos lsp.Position {line: integer, character: integer}
---@return integer lnum 1-indexed line number
---@return integer col 1-indexed column number
function M.to_vim_pos(pos)
  return to_vim_pos(pos)
end

--- Convert Neovim 1-indexed position to LSP 0-indexed Position (public).
---@param lnum integer 1-indexed line number
---@param col integer 1-indexed column number
---@return lsp.Position position {line: integer, character: integer}
function M.to_lsp_pos(lnum, col)
  return to_lsp_pos(lnum, col)
end

return M
