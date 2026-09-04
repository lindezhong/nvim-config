-- Pure Lua implementation of tree-sitter-html.
--
-- Parses HTML into a node tree with the same structure and API as
-- tree-sitter-html (grammar.js + scanner.c), so consumers like dict.lua
-- can switch from the native html.so parser without changing their walk
-- logic.
--
-- Node API mirrors TSNode: type(), child(i), child_count(),
-- iter_children(), named(), named_child(i), named_child_count(),
-- parent(), sexpr().
--
-- Usage:
--   local ts_html = require("tree_sitter_html")
--   local tree = ts_html.parse("<div class='x'>hello</div>")
--   local root = tree:root()           -- document node
--   print(root:sexpr())                -- (document (element ...))
--   print(ts_html.get_node_text(root)) -- full source text

local M = {}

---------------------------------------------------------------------------
-- Node class
---------------------------------------------------------------------------

local Node = {}
Node.__index = Node

local function new_node(ntype, named, text, children)
  local node = setmetatable({
    _type = ntype,
    _named = named,
    _text = text or "",
    _children = children or {},
    _parent = nil,
  }, Node)
  for _, child in ipairs(node._children) do
    child._parent = node
  end
  return node
end

local function new_anon(text)
  return new_node(text, false, text, {})
end

function Node:type()
  return self._type
end

function Node:named()
  return self._named
end

function Node:child(index)
  return self._children[index + 1]
end

function Node:child_count()
  return #self._children
end

function Node:iter_children()
  local i = 0
  local children = self._children
  local n = #children
  return function()
    i = i + 1
    if i <= n then return children[i] end
  end
end

function Node:named_child(index)
  local j = -1
  for _, child in ipairs(self._children) do
    if child._named then
      j = j + 1
      if j == index then return child end
    end
  end
end

function Node:named_child_count()
  local count = 0
  for _, child in ipairs(self._children) do
    if child._named then count = count + 1 end
  end
  return count
end

function Node:parent()
  return self._parent
end

function Node:sexpr()
  if not self._named then return nil end
  local named_kids = {}
  for _, child in ipairs(self._children) do
    if child._named then
      named_kids[#named_kids + 1] = child:sexpr()
    end
  end
  if #named_kids == 0 then
    return "(" .. self._type .. ")"
  end
  return "(" .. self._type .. "\n" .. table.concat(named_kids, "\n") .. ")"
end

---------------------------------------------------------------------------
-- Tree class
---------------------------------------------------------------------------

local Tree = {}
Tree.__index = Tree

local function new_tree(root)
  return setmetatable({ _root = root }, Tree)
end

function Tree:root()
  return self._root
end

---------------------------------------------------------------------------
-- Constants (from tag.h)
---------------------------------------------------------------------------

local VOID_ELEMENTS = {}
for _, tag in ipairs({
  "area", "base", "basefont", "bgsound", "br", "col", "command", "embed",
  "frame", "hr", "image", "img", "input", "isindex", "keygen", "link",
  "menuitem", "meta", "nextid", "param", "source", "track", "wbr",
}) do
  VOID_ELEMENTS[tag] = true
end

local RAW_TEXT_TAGS = { script = true, style = true }

local P_CLOSERS = {}
for _, tag in ipairs({
  "address", "article", "aside", "blockquote", "details", "div", "dl",
  "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3",
  "h4", "h5", "h6", "header", "hr", "main", "nav", "ol", "p", "pre",
  "section",
}) do
  P_CLOSERS[tag] = true
end

local function should_implicit_close(parent_tag, child_tag)
  if parent_tag == "li" then return child_tag == "li" end
  if parent_tag == "dt" or parent_tag == "dd" then
    return child_tag == "dt" or child_tag == "dd"
  end
  if parent_tag == "p" then return P_CLOSERS[child_tag] or false end
  if parent_tag == "colgroup" then return child_tag ~= "col" end
  if parent_tag == "rb" or parent_tag == "rt" or parent_tag == "rp" then
    return child_tag == "rb" or child_tag == "rt" or child_tag == "rp"
  end
  if parent_tag == "optgroup" then return child_tag == "optgroup" end
  if parent_tag == "tr" then return child_tag == "tr" end
  if parent_tag == "td" or parent_tag == "th" then
    return child_tag == "td" or child_tag == "th" or child_tag == "tr"
  end
  return false
end

---------------------------------------------------------------------------
-- Parser internals
---------------------------------------------------------------------------

--- Build start_tag or self_closing_tag node, consuming attributes.
--- @param html string
--- @param pos integer  position right after the tag name
--- @param tag_name_text string  the raw tag name as it appears in source
--- @return table node  start_tag or self_closing_tag node
--- @return integer pos  position after the closing > or />
--- @return boolean self_closing  whether the tag ended with />
local function parse_tag(html, pos, tag_name_text)
  local len = #html
  local children = { new_anon("<"), new_node("tag_name", true, tag_name_text, {}) }
  local self_closing = false

  -- Skip whitespace and parse attributes until > or />
  while pos <= len do
    -- Skip whitespace
    local ws_end = html:find("[^%s]", pos)
    if not ws_end then break end
    pos = ws_end

    local ch = html:byte(pos)

    -- Check for /> (self-closing)
    if ch == 0x2F and pos + 1 <= len and html:byte(pos + 1) == 0x3E then
      self_closing = true
      children[1] = new_anon("<") -- already set
      -- Replace the opening "<" with "<" and close with "/>"
      children[#children + 1] = new_anon("/>")
      pos = pos + 2
      break
    end

    -- Check for > (end of tag)
    if ch == 0x3E then
      children[#children + 1] = new_anon(">")
      pos = pos + 1
      break
    end

    -- Parse attribute
    -- Attribute name: [^<>"'/=\s]+
    local attr_name_start = pos
    while pos <= len do
      local b = html:byte(pos)
      if b == 0x3C or b == 0x3E or b == 0x22 or b == 0x27
        or b == 0x2F or b == 0x3D or b <= 0x20 then
        break
      end
      pos = pos + 1
    end

    if pos == attr_name_start then
      -- Not a valid attribute char, skip one byte to avoid infinite loop
      pos = pos + 1
      goto continue_attrs
    end

    local attr_name = html:sub(attr_name_start, pos - 1)
    local attr_children = { new_node("attribute_name", true, attr_name, {}) }

    -- Skip whitespace before potential =
    local eq_pos = html:find("[^%s]", pos)
    if eq_pos and html:byte(eq_pos) == 0x3D then
      -- Has value
      attr_children[#attr_children + 1] = new_anon("=")
      pos = eq_pos + 1

      -- Skip whitespace before value
      local val_start = html:find("[^%s]", pos)
      if val_start then
        pos = val_start
        local val_ch = html:byte(pos)

        if val_ch == 0x22 or val_ch == 0x27 then
          -- Quoted value
          local quote_char = html:sub(pos, pos)
          local quote_end = html:find(quote_char, pos + 1, true)
          if quote_end then
            local inner_text = html:sub(pos + 1, quote_end - 1)
            local qav_children = { new_anon(quote_char) }
            if #inner_text > 0 then
              qav_children[#qav_children + 1] = new_node("attribute_value", true, inner_text, {})
            end
            qav_children[#qav_children + 1] = new_anon(quote_char)
            local full_quoted = html:sub(pos, quote_end)
            attr_children[#attr_children + 1] = new_node("quoted_attribute_value", true, full_quoted, qav_children)
            pos = quote_end + 1
          else
            -- No closing quote, treat rest as value
            local rest = html:sub(pos + 1)
            local qav_children2 = { new_anon(quote_char) }
            if #rest > 0 then
              qav_children2[#qav_children2 + 1] = new_node("attribute_value", true, rest, {})
            end
            attr_children[#attr_children + 1] = new_node("quoted_attribute_value", true, html:sub(pos), qav_children2)
            pos = len + 1
          end
        else
          -- Unquoted value: [^<>"'=\s]+
          local uv_start = pos
          while pos <= len do
            local b = html:byte(pos)
            if b == 0x3C or b == 0x3E or b == 0x22 or b == 0x27
              or b == 0x3D or b <= 0x20 then
              break
            end
            pos = pos + 1
          end
          if pos > uv_start then
            attr_children[#attr_children + 1] = new_node("attribute_value", true, html:sub(uv_start, pos - 1), {})
          end
        end
      end
    else
      -- Boolean attribute (no value), restore pos
      if eq_pos then pos = eq_pos end
    end

    local attr_text_parts = {}
    for _, ac in ipairs(attr_children) do
      attr_text_parts[#attr_text_parts + 1] = ac._text
    end
    children[#children + 1] = new_node("attribute", true, table.concat(attr_text_parts), attr_children)

    ::continue_attrs::
  end

  local tag_type = self_closing and "self_closing_tag" or "start_tag"
  local text_parts = {}
  for _, c in ipairs(children) do
    text_parts[#text_parts + 1] = c._text
  end
  return new_node(tag_type, true, table.concat(text_parts), children), pos, self_closing
end

--- Build end_tag node.
--- @param tag_name_text string
--- @return table node
local function make_end_tag(tag_name_text)
  local children = {
    new_anon("</"),
    new_node("tag_name", true, tag_name_text, {}),
    new_anon(">"),
  }
  return new_node("end_tag", true, "</" .. tag_name_text .. ">", children)
end

--- Build an element node from a stack entry.
--- @param entry { tag: string, start_tag: table, children: table[] }
--- @param end_tag_node table|nil
--- @return table element node
local function build_element(entry, end_tag_node)
  local elem_children = { entry.start_tag }
  for _, child in ipairs(entry.children) do
    elem_children[#elem_children + 1] = child
  end
  if end_tag_node then
    elem_children[#elem_children + 1] = end_tag_node
  end
  local text_parts = {}
  for _, c in ipairs(elem_children) do
    text_parts[#text_parts + 1] = c._text
  end
  local elem_type = entry.raw_text_type or "element"
  return new_node(elem_type, true, table.concat(text_parts), elem_children)
end

--- Pop the top of the stack, build an element, append to new top.
--- @param stack table[]
local function pop_element(stack, end_tag_node)
  local entry = table.remove(stack)
  if not entry then return end
  local elem = build_element(entry, end_tag_node)
  local top = stack[#stack]
  if top then
    top.children[#top.children + 1] = elem
  end
  return elem
end

---------------------------------------------------------------------------
-- Main parser
---------------------------------------------------------------------------

--- Parse an HTML string into a tree with TSNode-compatible nodes.
--- @param html string
--- @return table tree  object with :root() method
function M.parse(html)
  local len = #html
  local pos = 1

  -- Stack of open elements. Each entry:
  --   { tag = string, start_tag = Node, children = Node[], raw_text_type = string|nil }
  -- Bottom entry is the document pseudo-element.
  local stack = { { tag = "", start_tag = nil, children = {} } }

  -- Accumulator for text content between tags
  local text_buf = {}
  local text_start = nil

  local function ensure_non_void_top()
    if #stack > 1 and stack[#stack].is_void then
      pop_element(stack, nil)
    end
  end

  local function flush_text()
    if #text_buf == 0 then return end
    local content = table.concat(text_buf)
    text_buf = {}
    text_start = nil
    content = content:match("^%s*(.-)%s*$") or ""
    if #content == 0 then return end
    ensure_non_void_top()
    stack[#stack].children[#stack[#stack].children + 1] =
      new_node("text", true, content, {})
  end

  while pos <= len do
    local ch = html:byte(pos)

    -- Check for < (tag start)
    if ch == 0x3C then
      flush_text()

      -- Comment: <!--
      if html:sub(pos, pos + 3) == "<!--" then
        local close = html:find("-->", pos + 4, true)
        local comment_end = close and close + 2 or len
        local comment_text = html:sub(pos, comment_end)
        ensure_non_void_top()
        stack[#stack].children[#stack[#stack].children + 1] =
          new_node("comment", true, comment_text, {})
        pos = comment_end + 1
        goto continue_main

      -- Doctype: <!DOCTYPE or <!doctype
      elseif html:sub(pos, pos + 1) == "<!" then
        local rest = html:sub(pos + 2, pos + 9)
        if rest:upper():sub(1, 7) == "DOCTYPE" then
          local gt = html:find(">", pos + 2, true)
          if gt then
            local doctype_text = html:sub(pos, gt)
            ensure_non_void_top()
            stack[#stack].children[#stack[#stack].children + 1] =
              new_node("doctype", true, doctype_text, {})
            pos = gt + 1
          else
            pos = pos + 2
          end
          goto continue_main
        end

      -- Close tag: </
      elseif html:byte(pos + 1) == 0x2F then
        local tag_start = pos + 2
        -- Skip whitespace after </
        while tag_start <= len and html:byte(tag_start) <= 0x20 do
          tag_start = tag_start + 1
        end
        -- Read tag name
        local tag_end = tag_start
        while tag_end <= len do
          local b = html:byte(tag_end)
          if b == 0x3E or b <= 0x20 then break end
          tag_end = tag_end + 1
        end
        local close_tag_name = html:sub(tag_start, tag_end - 1)
        local close_tag_lower = close_tag_name:lower()
        -- Find >
        local gt = html:find(">", tag_end, true)
        pos = gt and gt + 1 or len + 1

        -- Search stack for matching open tag
        local match_idx
        for i = #stack, 2, -1 do
          if stack[i].tag == close_tag_lower then
            match_idx = i
            break
          end
        end

        if match_idx then
          local end_tag_node = make_end_tag(close_tag_name)
          -- Pop everything above the match (implicit close)
          while #stack > match_idx do
            pop_element(stack, nil)
          end
          -- Pop the matched element with end_tag
          pop_element(stack, end_tag_node)
        end
        -- If no match, ignore the close tag (erroneous)
        goto continue_main

      -- Open tag
      else
        local tag_start = pos + 1
        local tag_end = tag_start
        while tag_end <= len do
          local b = html:byte(tag_end)
          if b == 0x3E or b == 0x2F or b <= 0x20 then break end
          tag_end = tag_end + 1
        end

        if tag_end == tag_start then
          -- Empty tag name, treat < as text
          text_buf[#text_buf + 1] = "<"
          pos = pos + 1
          goto continue_main
        end

        local tag_name_text = html:sub(tag_start, tag_end - 1)
        local tag_lower = tag_name_text:lower()

        -- Handle script/style (raw text elements)
        if RAW_TEXT_TAGS[tag_lower] then
          local start_tag_node, after_tag = parse_tag(html, tag_end, tag_name_text)
          pos = after_tag

          -- Scan for closing tag (case-insensitive)
          local close_pattern = "</%s*" .. tag_lower .. "%s*>"
          local raw_start = pos
          local close_start, close_end
          local search_pos = pos
          while search_pos <= len do
            local s, e = html:lower():find(close_pattern, search_pos)
            if s then
              close_start, close_end = s, e
              break
            end
            search_pos = search_pos + 1
          end

          local entry_children = {}
          if close_start then
            local raw_content = html:sub(raw_start, close_start - 1)
            if #raw_content > 0 then
              entry_children[#entry_children + 1] = new_node("raw_text", true, raw_content, {})
            end
            -- Extract actual close tag name from source (preserve original case)
            local actual_close = html:sub(close_start, close_end)
            local actual_name = actual_close:match("^</%s*(.-)%s*>$") or tag_name_text
            local end_tag_node = make_end_tag(actual_name)
            entry_children[#entry_children + 1] = end_tag_node
            pos = close_end + 1
          else
            -- No closing tag found, raw text until EOF
            local raw_content = html:sub(raw_start)
            if #raw_content > 0 then
              entry_children[#entry_children + 1] = new_node("raw_text", true, raw_content, {})
            end
            pos = len + 1
          end

          local elem_type = tag_lower == "script" and "script_element" or "style_element"
          local all_children = { start_tag_node }
          for _, c in ipairs(entry_children) do
            all_children[#all_children + 1] = c
          end
          local text_parts = {}
          for _, c in ipairs(all_children) do
            text_parts[#text_parts + 1] = c._text
          end
          local elem = new_node(elem_type, true, table.concat(text_parts), all_children)
          ensure_non_void_top()
          stack[#stack].children[#stack[#stack].children + 1] = elem
          goto continue_main
        end

        -- Regular open tag
        local start_tag_node, after_tag, is_self_closing = parse_tag(html, tag_end, tag_name_text)
        pos = after_tag

        ensure_non_void_top()
        if is_self_closing then
          -- Self-closing tag → element with single self_closing_tag child
          while #stack > 1 and should_implicit_close(stack[#stack].tag, tag_lower) do
            pop_element(stack, nil)
          end
          local elem = new_node("element", true, start_tag_node._text, { start_tag_node })
          stack[#stack].children[#stack[#stack].children + 1] = elem
        elseif VOID_ELEMENTS[tag_lower] then
          -- Void element → push to stack, implicitly closed when content arrives
          while #stack > 1 and should_implicit_close(stack[#stack].tag, tag_lower) do
            pop_element(stack, nil)
          end
          stack[#stack + 1] = {
            tag = tag_lower,
            start_tag = start_tag_node,
            children = {},
            is_void = true,
          }
        else
          -- Regular element → push onto stack
          while #stack > 1 and should_implicit_close(stack[#stack].tag, tag_lower) do
            pop_element(stack, nil)
          end
          stack[#stack + 1] = {
            tag = tag_lower,
            start_tag = start_tag_node,
            children = {},
          }
        end
        goto continue_main
      end
    end

    -- Check for & (potential entity outside tags)
    if ch == 0x26 then
      local entity_text
      local named = html:match("^(&[A-Za-z]+;?)", pos)
      if named then
        local alpha = named:match("^&([A-Za-z]+)")
        if alpha and #alpha >= 1 and #alpha <= 30 then
          entity_text = named
        end
      end
      if not entity_text then
        local hex = html:match("^(&#[xX]%x+;?)", pos)
        if hex then
          local digits = hex:match("^&#[xX](%x+)")
          if digits and #digits >= 1 and #digits <= 6 then
            entity_text = hex
          end
        end
      end
      if not entity_text then
        local dec = html:match("^(&#%d+;?)", pos)
        if dec then
          local digits = dec:match("^&#(%d+)")
          if digits and #digits >= 1 and #digits <= 5 then
            entity_text = dec
          end
        end
      end

      if entity_text then
        flush_text()
        ensure_non_void_top()
        stack[#stack].children[#stack[#stack].children + 1] =
          new_node("entity", true, entity_text, {})
        pos = pos + #entity_text
        goto continue_main
      end
    end

    -- Regular text character
    text_buf[#text_buf + 1] = html:sub(pos, pos)
    if not text_start then text_start = pos end
    pos = pos + 1

    ::continue_main::
  end

  -- Flush remaining text
  flush_text()

  -- Pop remaining stack entries (implicit close at EOF)
  while #stack > 1 do
    pop_element(stack, nil)
  end

  -- Build document node
  local doc = new_node("document", true, html, stack[1].children)
  return new_tree(doc)
end

--- Get the source text of a node (replaces vim.treesitter.get_node_text).
--- @param node table
--- @return string
function M.get_node_text(node)
  return node._text
end

return M
