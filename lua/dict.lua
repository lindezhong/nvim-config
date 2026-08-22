-- Singleton StarDict dictionary reader with async chunked loading and
-- configurable HTML rendering via tree-sitter.
--
-- Reads StarDict binary format (.idx required; .ifo/.dict/.dict.dz optional)
-- and provides prefix search with case-insensitive matching. Supports dictzip
-- random-access decompression via LuaJIT FFI + Neovim's bundled zlib.
--
-- File detection: pass any path sharing the dictionary's base name (e.g.
-- "foo.ifo", "foo.idx", "foo.dict", "foo.dict.dz") — the module strips the
-- extension and probes for each file. Only .idx is required; .ifo provides
-- content_type metadata (defaults to plain text if absent), .dict.dz/.dict
-- provide definition data (read_definition returns the word itself if absent).
--
-- The HTML renderer uses tree-sitter to walk the DOM and applies user-defined
-- actions (skip/replace/before/wrap/transform) matched by CSS-like selectors.
-- The html_map uses an ordered array format (not a hash table) because Lua
-- tables have no guaranteed key iteration order.
--
-- Translation interface:
--   :Translate [word]   print definition to messages (defaults to <cword>)
--   <leader>t (normal)  show definition in floating window for word under cursor
--   <leader>t (visual)  show definition in floating window for selected text
--   S-j / S-k           scroll the floating window without entering it
--   <leader>t again     enter the floating window for full navigation
--
-- Usage:
--   local dict = require("dict")
--   dict.setup({
--     path = "/path/to/dict.ifo",  -- or .idx / .dict / .dict.dz
--     html_map = {
--       -- Selectors: "tag", ".class", "#id", "tag.class", "tag#id"
--       { ".ad",        { type = "skip" } },                    -- discard element and children
--       { "br",         { type = "replace", value = "\n" } },   -- replace element with text
--       { "span.pos",   { type = "before", value = "\n" } },    -- prepend text before children
--       { "#phonetic",  { type = "wrap", before = "[", after = "]" } },  -- wrap children
--       { "div.def",    { type = "transform", fn = function(t) return t:upper() end } },
--     },
--   })
--   dict:on_ready(function()
--     local results = dict:search("hello")
--     local text = dict:read_definition(results[1].index)
--   end)

--- @type uv  libuv binding (vim.uv in nvim 0.10+, vim.loop in older)
local uv = vim.uv or vim.loop

-- LuaJIT FFI binding to zlib for dictzip (.dict.dz) random-access decompression.
-- Neovim links zlib at build time, so the library is always present in-process.
local ffi = require("ffi")
pcall(ffi.cdef, [[
typedef struct z_stream_s {
  const unsigned char *next_in;
  unsigned int avail_in;
  unsigned long total_in;
  unsigned char *next_out;
  unsigned int avail_out;
  unsigned long total_out;
  const char *msg;
  void *state;
  void *zalloc;
  void *zfree;
  void *opaque;
  int data_type;
  unsigned long adler;
  unsigned long reserved;
} z_stream;
const char *zlibVersion(void);
int inflateInit2_(z_stream *strm, int windowBits, const char *version, int stream_size);
int inflate(z_stream *strm, int flush);
int inflateEnd(z_stream *strm);
]])
local zlib_ok, zlib = pcall(ffi.load, ffi.os == "Windows" and "zlib1" or "z")

--- Number of index entries to parse per chunk before yielding to the event loop.
--- Lower values reduce per-frame blocking; higher values reduce total load time.
local ENTRIES_PER_CHUNK = 20000

--- @class dict.Entry
--- @field word string
--- @field offset integer
--- @field size integer

--- @class Dict
--- @field entries dict.Entry[]  sorted array of all dictionary entries
--- @field ready boolean  true after index is fully loaded and sorted
--- @field content_type string|nil  sametypesequence value from .ifo (e.g. "h")
--- @field idx_path string  absolute path to .idx binary index file
--- @field dict_path string|nil  path to .dict/.dict.dz file, nil if no definition data
--- @field _selectors { tag: string|nil, cls: string|nil, id: string|nil, action: table }[]  pre-compiled selector rules
--- @field _loading boolean  true while async loading is in progress (prevents duplicate setup)
--- @field _on_ready_cbs function[]  callbacks queued before ready, fired once on load completion
local M = {}
--- Sorted entry array; populated by _parse_chunked → _finalize.
M.entries = {}
--- Whether the dictionary is fully loaded and ready for queries.
M.ready = false
--- Guard flag to prevent concurrent/duplicate loading.
M._loading = false
--- Content type string from .ifo sametypesequence field; determines renderer.
M.content_type = nil
--- Pre-compiled selector rules from html_map, in definition order.
M._selectors = {}
--- Pending callbacks registered via on_ready() before loading completes.
M._on_ready_cbs = {}
--- Whether we're reading from a dictzip (.dict.dz) file.
M._use_dictzip = false
--- Uncompressed bytes per dictzip chunk (typically 58315).
M._dz_chunk_size = 0
--- File byte offsets for each compressed chunk (1-based, length = chunk_count + 1).
--- offsets[i+1] - offsets[i] = compressed size of chunk i (0-based).
M._dz_offsets = {}

-- Renderer dispatch table: content_type → function(self, data) → string
-- Currently supports: "h" (HTML). Unsupported types fall through to raw data.
M._renderers = {}

--- Configure and start loading the dictionary.
--- @param opts { path: string, html_map?: table }
function M.setup(opts)
  -- Require a valid path in opts
  if not opts or not opts.path then return end
  -- Prevent duplicate loading if already loaded or in progress
  if M.ready or M._loading then return end
  -- Mark as loading to block re-entry
  M._loading = true

  local base = opts.path:match("^(.+)%.dict%.dz$") or opts.path:match("^(.+)%.[^.]+$") or opts.path
  M.idx_path = base .. ".idx"

  local dz_path = base .. ".dict.dz"
  local dict_path = base .. ".dict"
  if uv.fs_stat(dz_path) then
    M.dict_path = dz_path
    M._use_dictzip = true
  elseif uv.fs_stat(dict_path) then
    M.dict_path = dict_path
  else
    M.dict_path = nil
  end

  M._show_word_header = opts.show_word_header ~= false

  -- Pre-compile selector rules from the ordered html_map array
  M._selectors = M._parse_html_map(opts.html_map or {})

  -- Parse .ifo if it exists to get content_type
  local ifo_path = base .. ".ifo"
  if uv.fs_stat(ifo_path) then
    M:_parse_ifo(ifo_path)
  end
  -- Parse dictzip header to build chunk offset table (sync, ~15KB)
  if M._use_dictzip then
    if not M:_parse_dz_header() then
      M._use_dictzip = false
      M.dict_path = uv.fs_stat(dict_path) and dict_path or nil
    end
  end
  -- Warn if HTML renderer is needed but tree-sitter html parser is missing
  if M.content_type == "h" and not pcall(vim.treesitter.language.inspect, "html") then
    vim.notify("dict: HTML dictionary requires tree-sitter html parser (:TSInstall html)", vim.log.levels.WARN)
  end
  -- :Translate [word] — print definition to messages
  vim.api.nvim_create_user_command("Translate", function(cmd)
    local arg = vim.trim(cmd.args)
    local word = arg ~= "" and arg or vim.fn.expand("<cword>")
    if word == "" then
      print("dict: empty input")
      return
    end
    if not M.ready then
      print("dict: not ready")
      return
    end
    local text = M:translate(word)
    if text then
      print(text)
    else
      print("dict: " .. word .. " not found")
    end
  end, { nargs = "?" })
  -- <leader>t (normal) — floating window for word under cursor
  vim.keymap.set("n", "<leader>t", function()
    M:show_translate(vim.fn.expand("<cword>"))
  end)
  -- <leader>t (visual) — floating window for selected text
  vim.keymap.set("x", "<leader>t", function()
    local region = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."))
    local word = table.concat(region, " "):gsub("^%s+", ""):gsub("%s+$", "")
    vim.cmd([[execute "normal! \<Esc>`<"]])
    vim.schedule(function()
      M:show_translate(word)
    end)
  end)

  -- Defer async loading by 50ms to avoid blocking startup
  vim.defer_fn(function()
    M:_load_async()
  end, 50)
end

--- @return boolean
function M:is_ready()
  return self.ready
end

--- Register a callback to be called when the dictionary is loaded.
--- @param cb function
function M:on_ready(cb)
  if self.ready then
    cb()
  else
    self._on_ready_cbs[#self._on_ready_cbs + 1] = cb
  end
end

--- Case-insensitive prefix search.
--- @param prefix string
--- @param max_items? integer  maximum results (0 or nil = unlimited)
--- @return { word: string, index: integer }[]
function M:search(prefix, max_items)
  if not self.ready or #prefix < 1 then
    return {}
  end

  local prefix_lower = prefix:lower()
  local start = self:_lower_bound(prefix_lower)
  local results = {}
  local entries = self.entries

  for i = start, #entries do
    local entry = entries[i]
    if entry.word:lower():sub(1, #prefix_lower) ~= prefix_lower then
      break
    end
    results[#results + 1] = { word = entry.word, index = i }
    if max_items and max_items > 0 and #results >= max_items then
      break
    end
  end

  return results
end

--- Read the definition text for an entry by index.
--- @param index integer
--- @return string
function M:read_definition(index)
  if not self.ready then return "" end
  local entry = self.entries[index]
  if not entry then return "" end

  if not self.dict_path then
    return entry.word
  end

  local data
  if self._use_dictzip then
    data = self:_read_dictzip(entry.offset, entry.size)
  else
    local fd = uv.fs_open(self.dict_path, "r", 438)
    if not fd then return "" end
    data = uv.fs_read(fd, entry.size, entry.offset)
    uv.fs_close(fd)
  end

  if not data then return "" end
  local renderer = self._renderers[self.content_type]
  local text = renderer and renderer(self, data) or data
  if self._show_word_header then
    return "[" .. entry.word .. "]\n\n" .. text
  end
  return text
end

--- Translate a word: exact match (case-insensitive) returning definition text.
--- @param word string
--- @return string|nil  definition text, or nil if not found
function M:translate(word)
  if not self.ready or not word or word == "" then return nil end
  local word_lower = word:lower()
  local lo, hi = 1, #self.entries
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local entry_lower = self.entries[mid].word:lower()
    if entry_lower == word_lower then
      return self:read_definition(mid)
    elseif entry_lower < word_lower then
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return nil
end

--- Show translation in a floating window (auto-closes on cursor move).
--- Press again while window is open to enter it for full navigation.
--- @param word string
function M:show_translate(word)
  if self._translate_win and vim.api.nvim_win_is_valid(self._translate_win) then
    -- Second press: enter existing floating window for full navigation
    local win = self._translate_win
    local float_buf = vim.api.nvim_win_get_buf(win)
    self._translate_win = nil
    pcall(vim.api.nvim_del_augroup_by_name, "dict_translate")
    pcall(vim.keymap.del, "n", "<S-j>", { buffer = self._translate_src_buf })
    pcall(vim.keymap.del, "n", "<S-k>", { buffer = self._translate_src_buf })
    self._translate_src_buf = nil
    self._translate_win = win
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_create_autocmd("WinLeave", {
      buffer = float_buf,
      once = true,
      callback = function()
        pcall(vim.api.nvim_win_close, win, true)
        self._translate_win = nil
      end,
    })
    return
  end
  local text
  if not word or word == "" then
    text = "dict: empty input"
  elseif not self.ready then
    text = "dict: not ready"
  else
    text = self:translate(word) or ("dict: " .. word .. " not found")
  end
  local lines = vim.split(text, "\n")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local height = math.min(#lines, 20)
  local lines_below = vim.o.lines - vim.fn.screenrow() - 1
  local row = lines_below >= height and 1 or -height
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = row,
    col = 0,
    width = math.max(1, math.min(width, vim.o.columns - 4)),
    height = height,
    style = "minimal",
  })
  self._translate_win = win
  local src_buf = vim.api.nvim_get_current_buf()
  self._translate_src_buf = src_buf
  local group = vim.api.nvim_create_augroup("dict_translate", { clear = true })
  -- S-j/S-k scroll the floating window without entering it
  vim.keymap.set("n", "<S-j>", function()
    vim.api.nvim_win_call(win, function() vim.cmd([[execute "normal! \<C-f>"]]) end)
  end, { buffer = src_buf })
  vim.keymap.set("n", "<S-k>", function()
    vim.api.nvim_win_call(win, function() vim.cmd([[execute "normal! \<C-b>"]]) end)
  end, { buffer = src_buf })
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter" }, {
    group = group,
    buffer = src_buf,
    callback = function(ev)
      if ev.event ~= "InsertEnter" then
        local pos = vim.api.nvim_win_get_cursor(0)
        if pos[1] == cursor_pos[1] and pos[2] == cursor_pos[2] then
          return
        end
      end
      self:_close_translate_float()
      return true
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    buffer = src_buf,
    once = true,
    callback = function()
      self:_close_translate_float()
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      self:_close_translate_float()
    end,
  })
end

--- Close the translate floating window and clean up all associated state.
function M:_close_translate_float()
  local win = self._translate_win
  if not win then return end
  self._translate_win = nil
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  pcall(vim.api.nvim_del_augroup_by_name, "dict_translate")
  pcall(vim.keymap.del, "n", "<S-j>", { buffer = self._translate_src_buf })
  pcall(vim.keymap.del, "n", "<S-k>", { buffer = self._translate_src_buf })
  self._translate_src_buf = nil
end

--- Parse a CSS-like selector string into its tag, class, and id components.
--- Supported formats: "tag", ".class", "#id", "tag.class", "tag#id"
--- @param selector string  raw selector string (e.g. "span.DC", ".phonetic", "br")
--- @return string|nil tag  element tag name, or nil if selector is class/id only
--- @return string|nil cls  class name, or nil if not a class selector
--- @return string|nil id   id value, or nil if not an id selector
function M._parse_selector(selector)
  -- Try "tag.class" format (e.g. "span.DC")
  local tag, cls = selector:match("^(%a[%w-]*)%.([%w_-]+)$")
  if tag then return tag, cls, nil end
  -- Try "tag#id" format (e.g. "div#header")
  local tag2, id = selector:match("^(%a[%w-]*)#([%w_-]+)$")
  if tag2 then return tag2, nil, id end
  -- Try ".class" format (e.g. ".DC")
  local cls2 = selector:match("^%.([%w_-]+)$")
  if cls2 then return nil, cls2, nil end
  -- Try "#id" format (e.g. "#main")
  local id2 = selector:match("^#([%w_-]+)$")
  if id2 then return nil, nil, id2 end
  -- Bare tag name (e.g. "br", "span")
  return selector, nil, nil
end

--- Pre-parse html_map ordered array into a compiled selector list.
--- Called once at setup() time so matching at render time only does comparisons.
--- @param html_map { [1]: string, [2]: table }[]  ordered array of {selector, action} pairs
--- @return { tag: string|nil, cls: string|nil, id: string|nil, action: table }[]
function M._parse_html_map(html_map)
  local selectors = {}
  for _, entry in ipairs(html_map) do
    -- Decompose each selector string into its components
    local tag, cls, id = M._parse_selector(entry[1])
    selectors[#selectors + 1] = { tag = tag, cls = cls, id = id, action = entry[2] }
  end
  return selectors
end

--- Check if a single compiled selector matches the given element's tag/classes/id.
--- All non-nil selector fields must match (AND logic).
--- @param sel { tag: string|nil, cls: string|nil, id: string|nil }  compiled selector
--- @param tag string|nil  element's tag name
--- @param classes string[]|nil  element's class list (split from class attribute)
--- @param id string|nil  element's id attribute value
--- @return boolean
function M._selector_matches(sel, tag, classes, id)
  -- Tag must match if specified in selector
  if sel.tag and sel.tag ~= tag then return false end
  -- ID must match if specified in selector
  if sel.id and sel.id ~= id then return false end
  -- Class must be present in element's class list if specified
  if sel.cls then
    if not classes then return false end
    local found = false
    for _, c in ipairs(classes) do
      if c == sel.cls then found = true; break end
    end
    if not found then return false end
  end
  return true
end

--- Find all matching actions for an element by testing each selector in order.
--- Returns actions in html_map definition order (determines composition priority).
--- @param tag string|nil  element's tag name
--- @param classes string[]|nil  element's class list
--- @param id string|nil  element's id value
--- @return table[]  list of matched action tables
function M:_match_selectors(tag, classes, id)
  local actions = {}
  for _, sel in ipairs(self._selectors) do
    if M._selector_matches(sel, tag, classes, id) then
      actions[#actions + 1] = sel.action
    end
  end
  return actions
end

--- Apply multiple actions to control how an element's content is rendered.
--- Composition rules (in html_map definition order):
---   skip      — any skip discards the element and all its children
---                { type = "skip" }
---   replace   — all replace values concatenated, children discarded
---                { type = "replace", value = "■ " }
---   before    — all values prepended before children's text
---                { type = "before", value = "\n" }
---   wrap      — before/after values nest (first rule outermost)
---                { type = "wrap", before = "[", after = "]" }
---   transform — fns chained in order, each receives previous output
---                { type = "transform", fn = function(text) return "[" .. text .. "]" end }
--- @param actions table[]  list of matched actions to compose
--- @param parts string[]  output accumulator (text fragments)
--- @param walk_children function  callback to recurse into child nodes; accepts optional target table
function M._apply_actions(actions, parts, walk_children)
  -- No actions: pass through to children unchanged
  if #actions == 0 then
    walk_children()
    return
  end

  -- Skip takes highest priority: any skip discards the entire element
  for _, a in ipairs(actions) do
    if a.type == "skip" then return end
  end

  -- Replace takes next priority: concatenate all replace values, discard children
  local has_replace = false
  for _, a in ipairs(actions) do
    if a.type == "replace" then
      parts[#parts + 1] = a.value
      has_replace = true
    end
  end
  if has_replace then return end

  -- Collect before/wrap-before values and transform functions
  local transforms = {}
  for _, a in ipairs(actions) do
    if a.type == "before" then
      -- Insert before-value ahead of children
      parts[#parts + 1] = a.value
    elseif a.type == "wrap" and a.before then
      -- Wrap-before goes after any before values (nesting: first rule outermost)
      parts[#parts + 1] = a.before
    elseif a.type == "transform" and a.fn then
      -- Collect transform fns for chained application
      transforms[#transforms + 1] = a.fn
    end
  end

  -- Walk children: if transforms exist, collect into separate buffer and chain
  if #transforms > 0 then
    local collected = {}
    walk_children(collected)
    local text = table.concat(collected)
    -- Apply each transform in definition order
    for _, fn in ipairs(transforms) do
      text = fn(text)
    end
    parts[#parts + 1] = text
  else
    -- No transforms: walk children directly into parts
    walk_children()
  end

  -- Append wrap-after values in reverse order (first rule outermost → last to close)
  for i = #actions, 1, -1 do
    local a = actions[i]
    if a.type == "wrap" and a.after then
      parts[#parts + 1] = a.after
    end
  end
end

--- Extract tag name, class list, and id from a tree-sitter start_tag or
--- self_closing_tag node by iterating its child nodes.
--- @param node userdata  tree-sitter node of type "start_tag" or "self_closing_tag"
--- @param buf integer  buffer handle containing the HTML source
--- @return string|nil tag  the element's tag name
--- @return string[]|nil classes  list of class names (split on whitespace)
--- @return string|nil id  the element's id attribute value
function M._extract_tag_info(node, buf)
  local tag, classes, id
  for child in node:iter_children() do
    if child:type() == "tag_name" then
      -- Extract tag name text (e.g. "span", "div")
      tag = vim.treesitter.get_node_text(child, buf)
    elseif child:type() == "attribute" then
      -- Attribute node structure: name_node, "=", value_node
      local name_node = child:child(0)
      if name_node then
        local attr_name = vim.treesitter.get_node_text(name_node, buf)
        -- Value node is the 3rd child (index 2): quoted_attribute_value
        local val_node = child:child(2)
        if val_node then
          -- Strip both single and double quotes from the raw value text
          local val = vim.treesitter.get_node_text(val_node, buf):gsub('["\']', "")
          if attr_name == "class" then
            -- Split on whitespace to support multi-class attributes
            classes = vim.split(val, "%s+", { trimempty = true })
          elseif attr_name == "id" then
            id = val
          end
        end
      end
    end
  end
  return tag, classes, id
end

--- Convert HTML dictionary content to plain text using tree-sitter parsing.
--- Creates a temporary buffer, parses with the HTML grammar, walks the tree
--- applying matched actions, then cleans up. Falls back to regex tag stripping
--- if tree-sitter is unavailable or parsing fails.
--- @param html string  raw HTML content from the .dict file
--- @return string  rendered plain text
function M:_html_to_text(html)
  -- Create an unlisted scratch buffer to hold HTML for tree-sitter parsing
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(html, "\n"))

  -- Attempt to get the HTML tree-sitter parser for this buffer
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "html")
  if not ok or not parser then
    -- Fallback: strip all HTML tags with regex if parser unavailable
    vim.api.nvim_buf_delete(buf, { force = true })
    return (html:gsub("<[^>]+>", ""))
  end

  -- Parse the buffer; handle empty/invalid HTML returning no trees
  local trees = parser:parse()
  if not trees[1] then
    vim.api.nvim_buf_delete(buf, { force = true })
    return (html:gsub("<[^>]+>", ""))
  end
  local root = trees[1]:root()

  --- Recursively walk the tree-sitter AST, collecting text into parts.
  --- @param node userdata  current tree-sitter node
  --- @param parts string[]  output accumulator
  local function walk(node, parts)
    local ntype = node:type()
    -- Leaf nodes: plain text content and HTML entities (e.g. &amp; &lt;)
    if ntype == "text" or ntype == "entity" then
      local text = vim.treesitter.get_node_text(node, buf)
      if text and text ~= "" then
        parts[#parts + 1] = text
      end
      return
    end
    -- Self-closing tags (e.g. <br/>, <img/>): no children to recurse into
    if ntype == "self_closing_tag" then
      local tag, classes, id = M._extract_tag_info(node, buf)
      local actions = self:_match_selectors(tag, classes, id)
      -- Check for skip first (consistent with _apply_actions priority)
      for _, a in ipairs(actions) do
        if a.type == "skip" then return end
      end
      -- Only "replace" is meaningful for self-closing tags (no children)
      for _, a in ipairs(actions) do
        if a.type == "replace" then
          parts[#parts + 1] = a.value
        end
      end
      return
    end
    -- Regular elements: match selectors on start_tag, apply actions
    if ntype == "element" then
      local start_tag = node:child(0)
      if start_tag and start_tag:type() == "start_tag" then
        local tag, classes, id = M._extract_tag_info(start_tag, buf)
        local actions = self:_match_selectors(tag, classes, id)
        if #actions > 0 then
          -- Apply composed actions; walk_children skips start_tag/end_tag nodes
          M._apply_actions(actions, parts, function(target)
            target = target or parts
            for child in node:iter_children() do
              local ct = child:type()
              -- Skip structural nodes that don't contain renderable content
              if ct ~= "start_tag" and ct ~= "end_tag" then
                walk(child, target)
              end
            end
          end)
          return
        end
      end
    end
    -- Generic fallthrough: recurse into all children (handles document, fragment, etc.)
    for child in node:iter_children() do
      walk(child, parts)
    end
  end

  -- Wrap walk in pcall to guarantee buffer cleanup on any error
  local ok2, result = pcall(function()
    local parts = {}
    walk(root, parts)
    local text = table.concat(parts)
    -- Collapse multiple consecutive newlines into one
    text = text:gsub("\n\n+", "\n")
    -- Trim leading and trailing whitespace
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
  end)
  -- Always delete the temporary buffer regardless of success/failure
  vim.api.nvim_buf_delete(buf, { force = true })
  -- On error, fall back to regex tag stripping
  if not ok2 then return (html:gsub("<[^>]+>", "")) end
  return result
end

--- Binary search: find first index where entries[i].word:lower() >= prefix_lower
--- @param prefix_lower string  already lowercased
--- @return integer
function M:_lower_bound(prefix_lower)
  local lo, hi = 1, #self.entries
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if self.entries[mid].word:lower() < prefix_lower then
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return lo
end

--- Parse .ifo file to extract metadata.
--- @param ifo_path string
function M:_parse_ifo(ifo_path)
  local fd = uv.fs_open(ifo_path, "r", 438)
  if not fd then return end
  local stat = uv.fs_fstat(fd)
  if not stat or stat.size == 0 then
    uv.fs_close(fd)
    return
  end
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data then return end

  for line in data:gmatch("[^\r\n]+") do
    local key, val = line:match("^(.-)=(.+)$")
    if key == "sametypesequence" then
      self.content_type = val
    end
  end
end

--- Parse dictzip (.dict.dz) gzip header to build the chunk offset table.
--- Must be called after M.dict_path is set to the .dz file.
--- @return boolean  true on success, false on any parse failure
function M:_parse_dz_header()
  if not zlib_ok then
    vim.notify("dict: zlib not available, cannot read .dict.dz", vim.log.levels.WARN)
    return false
  end

  local fd = uv.fs_open(self.dict_path, "r", 438)
  if not fd then return false end

  local hdr = uv.fs_read(fd, 14, 0)
  if not hdr or #hdr < 14 then uv.fs_close(fd); return false end
  if hdr:byte(1) ~= 0x1F or hdr:byte(2) ~= 0x8B then uv.fs_close(fd); return false end
  local flags = hdr:byte(4)
  local has_extra = bit.band(flags, 0x04) ~= 0
  local has_name = bit.band(flags, 0x08) ~= 0
  local has_comment = bit.band(flags, 0x10) ~= 0
  local has_hcrc = bit.band(flags, 0x02) ~= 0
  if not has_extra then uv.fs_close(fd); return false end

  local xlen = hdr:byte(11) + hdr:byte(12) * 256
  local extra = uv.fs_read(fd, xlen, 10 + 2)
  if not extra or #extra < 10 then uv.fs_close(fd); return false end
  if extra:sub(1, 2) ~= "RA" then uv.fs_close(fd); return false end

  local chunk_size = extra:byte(7) + extra:byte(8) * 256
  local chunk_count = extra:byte(9) + extra:byte(10) * 256
  if chunk_size == 0 or chunk_count == 0 then uv.fs_close(fd); return false end

  -- RA subfield: 2(SI) + 2(sublen) + 2(ver) + 2(chlen) + 2(chcnt) = 10 bytes header
  local RA_HEADER_SIZE = 10
  if #extra < RA_HEADER_SIZE + chunk_count * 2 then uv.fs_close(fd); return false end

  -- Compressed data starts after: 10(gzip hdr) + 2(xlen field) + xlen(extra data)
  local pos = 10 + 2 + xlen
  if has_name then
    local name_buf = uv.fs_read(fd, 256, pos)
    if not name_buf then uv.fs_close(fd); return false end
    local null = name_buf:find("\0", 1, true)
    if not null then uv.fs_close(fd); return false end
    pos = pos + null
  end
  if has_comment then
    local cbuf = uv.fs_read(fd, 256, pos)
    if not cbuf then uv.fs_close(fd); return false end
    local null = cbuf:find("\0", 1, true)
    if not null then uv.fs_close(fd); return false end
    pos = pos + null
  end
  if has_hcrc then pos = pos + 2 end

  local offsets = {}
  offsets[1] = pos
  for i = 1, chunk_count do
    local idx = RA_HEADER_SIZE + (i - 1) * 2
    local comp_size = extra:byte(idx + 1) + extra:byte(idx + 2) * 256
    offsets[i + 1] = offsets[i] + comp_size
  end

  self._dz_chunk_size = chunk_size
  self._dz_offsets = offsets
  uv.fs_close(fd)
  return true
end

--- Decompress a raw DEFLATE buffer using zlib (windowBits=-15).
--- @param compressed string  raw deflate data
--- @param max_out integer  maximum output size (= chunk_size)
--- @return string
function M._inflate_raw(compressed, max_out)
  if max_out <= 0 or max_out > 65536 then return "" end
  local stream = ffi.new("z_stream")
  local out_buf = ffi.new("unsigned char[?]", max_out)
  stream.next_in = ffi.cast("const unsigned char*", compressed)
  stream.avail_in = #compressed
  stream.next_out = out_buf
  stream.avail_out = max_out
  if zlib.inflateInit2_(stream, -15, zlib.zlibVersion(), ffi.sizeof("z_stream")) ~= 0 then
    return ""
  end
  local ret = zlib.inflate(stream, 4) -- Z_FINISH
  local n = max_out - stream.avail_out
  zlib.inflateEnd(stream)
  if ret ~= 1 and n == 0 then return "" end -- Z_STREAM_END = 1
  return ffi.string(out_buf, n)
end

--- Read arbitrary range from dictzip file by inflating relevant chunks.
--- @param offset integer  byte offset in uncompressed data
--- @param size integer  number of bytes to read
--- @return string
function M:_read_dictzip(offset, size)
  if size <= 0 then return "" end
  local cs = self._dz_chunk_size
  if cs == 0 or #self._dz_offsets == 0 then return "" end
  local first = math.floor(offset / cs)
  local last = math.floor((offset + size - 1) / cs)

  local fd = uv.fs_open(self.dict_path, "r", 438)
  if not fd then return "" end

  local parts = {}
  for i = first, last do
    if not self._dz_offsets[i + 1] or not self._dz_offsets[i + 2] then break end
    local comp_offset = self._dz_offsets[i + 1]
    local comp_size = self._dz_offsets[i + 2] - comp_offset
    local compressed = uv.fs_read(fd, comp_size, comp_offset)
    if not compressed then break end
    local chunk_data = M._inflate_raw(compressed, cs)
    if #chunk_data == 0 then break end
    parts[#parts + 1] = chunk_data
  end
  uv.fs_close(fd)

  local full = table.concat(parts)
  local start_pos = offset - first * cs + 1
  return full:sub(start_pos, start_pos + size - 1)
end

--- Start async loading of the .idx file via libuv non-blocking I/O.
--- On failure at any stage, resets _loading to false to allow retry.
function M:_load_async()
  uv.fs_open(self.idx_path, "r", 438, function(err, fd)
    if err or not fd then
      vim.schedule(function()
        -- Reset loading flag so setup() can be retried
        self._loading = false
        vim.notify("dict: failed to open " .. self.idx_path, vim.log.levels.WARN)
      end)
      return
    end
    uv.fs_fstat(fd, function(err2, stat)
      if err2 or not stat then
        uv.fs_close(fd)
        -- Reset on stat failure
        self._loading = false
        return
      end
      uv.fs_read(fd, stat.size, 0, function(err3, data)
        uv.fs_close(fd)
        -- Reset on read failure
        if err3 or not data then self._loading = false; return end
        -- Schedule chunked parsing on the main thread
        vim.schedule(function()
          self:_parse_chunked(data, 1, {}, 0)
        end)
      end)
    end)
  end)
end

--- Parse .idx binary data in chunks to avoid blocking the main thread.
--- @param data string  raw binary
--- @param pos integer  current byte position
--- @param entries dict.Entry[]  accumulated entries
--- @param n integer  current entry count
function M:_parse_chunked(data, pos, entries, n)
  local len = #data
  local count = 0

  while pos <= len and count < ENTRIES_PER_CHUNK do
    local null_pos = data:find("\0", pos, true)
    if not null_pos or null_pos + 8 > len then
      pos = len + 1
      break
    end

    local word = data:sub(pos, null_pos - 1)

    local b1, b2, b3, b4 = data:byte(null_pos + 1, null_pos + 4)
    local offset = b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4

    local b5, b6, b7, b8 = data:byte(null_pos + 5, null_pos + 8)
    local size = b5 * 0x1000000 + b6 * 0x10000 + b7 * 0x100 + b8

    n = n + 1
    entries[n] = { word = word, offset = offset, size = size }
    pos = null_pos + 9
    count = count + 1
  end

  if pos <= len then
    vim.defer_fn(function()
      self:_parse_chunked(data, pos, entries, n)
    end, 0)
  else
    self:_finalize(entries, n)
  end
end

--- Finalize loading: verify sort order, store entries, fire callbacks.
--- @param entries dict.Entry[]
--- @param n integer
function M:_finalize(entries, n)
  local sorted = true
  for i = 2, n do
    if entries[i].word:lower() < entries[i - 1].word:lower() then
      sorted = false
      break
    end
  end

  if not sorted then
    for i = 1, n do
      entries[i].key = entries[i].word:lower()
    end
    table.sort(entries, function(a, b)
      return a.key < b.key
    end)
    for i = 1, n do
      entries[i].key = nil
    end
  end

  self.entries = entries
  self.ready = true

  for _, cb in ipairs(self._on_ready_cbs) do
    cb()
  end
  self._on_ready_cbs = {}
end

-- Register built-in renderers
M._renderers["h"] = M._html_to_text

return M
