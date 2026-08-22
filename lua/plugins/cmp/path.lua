-- Custom filesystem path completion source for nvim-cmp.
--
-- Replaces the external hrsh7th/cmp-path plugin with a built-in implementation.
-- Path recognition logic follows coc.nvim's native file source (getLastPart + path
-- classification); only the completion interface adapts to nvim-cmp's source API.
--
-- Supported path kinds:
--   absolute:  /usr/local/bin/
--   relative:  ./src/  or  src/
--   parent:    ../lib/
--   home:      ~/docs/  or  $HOME/docs/
--   env:       $GOPATH/src/

--- @type cmp  nvim-cmp core module (provides lsp.CompletionItemKind, lsp.MarkupKind)
local cmp = require("cmp")

--- @class cmp_path.Source  Custom nvim-cmp source for filesystem path completion.
local source = {}

--- Characters that terminate the backwards path scan.
--- When scanning the line leftward to find where the path begins, hitting any of
--- these characters stops the scan (the path starts after the character).
--- Ported from coc.nvim's file source invalid-character set.
--- @type table<string, boolean>
local INVALID_CHARS = {
  ["#"] = true, ["<"] = true, ["+"] = true,
  ["%"] = true, [">"] = true, ["!"] = true, ["`"] = true,
  ["&"] = true, ["*"] = true, ["'"] = true, ["|"] = true,
  ["{"] = true, ["?"] = true, ['"'] = true, ["="] = true,
  ["}"] = true, ["@"] = true,
}

--- Maximum number of lines shown in the documentation preview popup.
--- @type integer
local MAX_PREVIEW_LINES = 20

--- Default option values for the path source.
--- Can be overridden per-source via `sources = { { name = "path", option = {...} } }`.
--- @type cmp_path.Option
local defaults = {
  --- Whether to append a trailing slash to the *inserted* text for directories.
  --- @type boolean
  trailing_slash = false,
  --- Whether to show a trailing slash on the *label* (menu display) for directories.
  --- @type boolean
  label_trailing_slash = true,
  --- Returns the working directory used to resolve relative paths.
  --- Defaults to the directory of the buffer that triggered completion.
  --- @type fun(params: cmp.SourceCompletionApiParams): string
  get_cwd = function(params)
    -- "#N:p:h" expands buffer N's full path, then strips the filename (:h = head)
    return vim.fn.expand(("#%d:p:h"):format(params.context.bufnr))
  end,
}

--- Create a new source instance.
--- Called once by `cmp.register_source()` at startup.
--- @return cmp_path.Source
source.new = function()
  return setmetatable({}, { __index = source })
end

--- Return characters that should trigger path completion automatically.
--- "/" starts a new path segment; "." may start a hidden file or "./" prefix.
--- @return string[]
source.get_trigger_characters = function()
  return { "/", "." }
end

--- Return the Vim regex pattern used by nvim-cmp to detect the keyword under cursor.
--- Matches any sequence of characters that are valid within a path filename segment.
--- @return string
source.get_keyword_pattern = function()
  return [[\%([^/\\:\*?<>'"`\| ]\)*]]
end

--- Main completion entry point.  Called by nvim-cmp when completion is triggered.
--- Parses the cursor line to extract a path, resolves it to a directory, then
--- scans that directory and returns matching items via the callback.
--- @param self cmp_path.Source
--- @param params cmp.SourceCompletionApiParams  Completion context from nvim-cmp
--- @param callback fun(items?: lsp.CompletionItem[])  Invoke with results or nil
source.complete = function(self, params, callback)
  -- Merge user-provided per-source options with defaults
  local option = self:_validate_option(params)
  -- Text from line start up to (but not including) the cursor position
  local line = params.context.cursor_before_line

  -- Attempt to parse a filesystem path from the end of the line
  local root, input = self:_get_path_option(line, params, option)
  if not root then
    -- No valid path detected; yield no completions
    return callback()
  end

  -- Show dotfiles only when user explicitly typed a leading "."
  local include_hidden = input:sub(1, 1) == "."
  -- 0-based line number (LSP protocol)
  local cursor_line = params.context.cursor.row - 1
  -- 0-based byte column of cursor (cursor_before_line length is always 0-based)
  local cursor_col = #params.context.cursor_before_line
  -- Byte column where the typed input (filename part) begins
  local input_start = cursor_col - #input

  -- Scan the resolved directory for entries
  self:_candidates(root, include_hidden, option, function(err, candidates)
    if err then
      -- Filesystem error; silently yield no completions
      return callback()
    end
    -- Attach a textEdit to each item so nvim-cmp replaces exactly the typed input
    for _, item in ipairs(candidates) do
      item.textEdit = {
        -- LSP TextEdit range: [start, end) — replaces the filename portion
        range = {
          start = { line = cursor_line, character = input_start },
          ["end"] = { line = cursor_line, character = cursor_col },
        },
        newText = item.insertText,
      }
    end
    -- Deliver results to nvim-cmp
    callback(candidates)
  end)
end

--- Resolve additional information for a completion item (documentation preview).
--- Called lazily by nvim-cmp when the user highlights an item in the popup.
--- For file entries, reads the first few lines and displays them as documentation.
--- @param self cmp_path.Source
--- @param completion_item lsp.CompletionItem  The item to enrich
--- @param callback fun(item: lsp.CompletionItem)  Return the enriched item
source.resolve = function(self, completion_item, callback)
  local data = completion_item.data
  -- Only generate previews for regular files (not directories or symlinks)
  if data.stat and data.stat.type == "file" then
    -- pcall guards against I/O errors (permission denied, file vanished, etc.)
    local ok, documentation = pcall(self._get_documentation, self, data.path, MAX_PREVIEW_LINES)
    if ok then
      completion_item.documentation = documentation
    end
  end
  callback(completion_item)
end

--- Scan the line text backwards to extract the rightmost path-like substring.
--- Stops at any INVALID_CHARS character or an unescaped space.
--- Mirrors coc.nvim's `getLastPart()` function.
--- @param _ cmp_path.Source  (unused self)
--- @param text string  The text to scan (typically cursor_before_line)
--- @return string  The extracted trailing segment that may contain a path
source._get_last_part = function(_, text)
  local i = #text
  while i >= 1 do
    local ch = text:sub(i, i)
    -- Stop at any character that cannot appear in a filesystem path context
    if INVALID_CHARS[ch] then
      return text:sub(i + 1)
    end
    -- Stop at unescaped space (backslash-escaped spaces are part of the path)
    if ch == " " and (i <= 1 or text:sub(i - 1, i - 1) ~= "\\") then
      return text:sub(i + 1)
    end
    i = i - 1
  end
  -- No terminator found; the entire text is the candidate
  return text
end

--- Classify the extracted text into a path kind.
--- Returns the path string and its kind, or nil if it doesn't look like a path.
--- @param _ cmp_path.Source  (unused self)
--- @param part string  Text extracted by _get_last_part
--- @return string|nil pathstr  The path string (same as input if matched)
--- @return string|nil kind  One of: "parent","relative","home","env","absolute", or nil
source._match_path = function(_, part)
  -- Must contain at least one "/" to be a path
  if not part:find("/") then return nil, nil end
  -- Double slash ("//") is not a valid filesystem path (likely a URL or comment)
  if part:find("//") then return nil, nil end
  -- Reject URI schemes like "http:/", "ftp:/"
  if part:match("^%a+:/") then return nil, nil end
  -- Reject numeric prefixes like "123/" (likely a date or fraction)
  if part:match("^%d+/") then return nil, nil end

  -- Classify by prefix pattern (order matters: more specific patterns first)
  if part:match("^%.%./") then return part, "parent" end    -- ../
  if part:match("^%./") then return part, "relative" end    -- ./
  if part:match("^~/") then return part, "home" end         -- ~/
  if part:match("^%$HOME/") then return part, "home" end    -- $HOME/
  if part:match("^%$%w+/") then return part, "env" end      -- $VARNAME/
  if part:match("^/") then return part, "absolute" end      -- /
  -- Bare name followed by slash: treat as relative path (e.g. "src/")
  if part:match("^[%w_.%-]+/") then return part, "relative" end

  return nil, nil
end

--- Resolve the root directory to scan, based on the classified path kind.
--- @param _ cmp_path.Source  (unused self)
--- @param pathstr string  The path text from _match_path
--- @param kind string  The path kind from _match_path
--- @param params cmp.SourceCompletionApiParams  Completion context
--- @param option cmp_path.Option  Validated source options
--- @return string|nil  Resolved absolute directory path, or nil if unresolvable
source._resolve_root = function(_, pathstr, kind, params, option)
  -- Base directory for resolving relative paths
  local buf_dirname = option.get_cwd(params)
  -- In command-line mode, use cwd instead of buffer directory
  if vim.api.nvim_get_mode().mode == "c" then
    buf_dirname = vim.fn.getcwd()
  end

  --- @type string|nil
  local dirname
  if kind == "absolute" then
    -- "/usr/lib/" → use directly; "/usr/lib/foo" → parent dir "/usr/lib"
    dirname = pathstr:match("/$") and pathstr or vim.fn.fnamemodify(pathstr, ":h")
  elseif kind == "home" then
    -- Expand ~ or $HOME to the user's home directory
    local home = vim.fn.expand("~")
    --- @type string
    local expanded
    if pathstr:sub(1, 1) == "~" then
      -- "~/docs" → "/home/user/docs"
      expanded = home .. pathstr:sub(2)
    else
      -- "$HOME/docs" → "/home/user/docs" (skip past "$HOME" prefix)
      expanded = home .. pathstr:sub(#"$HOME" + 1)
    end
    dirname = expanded:match("/$") and expanded or vim.fn.fnamemodify(expanded, ":h")
  elseif kind == "env" then
    -- Extract the variable name and expand it
    local var = pathstr:match("^%$(%w+)")
    local val = vim.fn.getenv(var)
    -- Bail if the env var is unset or empty
    if val == vim.NIL or val == "" then return nil end
    -- Replace "$VAR" prefix with its value
    local expanded = val .. pathstr:sub(#var + 2)
    dirname = expanded:match("/$") and expanded or vim.fn.fnamemodify(expanded, ":h")
  elseif kind == "parent" or kind == "relative" then
    -- Prepend the buffer's directory to make an absolute path
    local full = buf_dirname .. "/" .. pathstr
    dirname = full:match("/$") and full or vim.fn.fnamemodify(full, ":h")
  end

  -- If none of the branches matched (shouldn't happen), bail
  if not dirname then return nil end
  -- Resolve symlinks to get the canonical path
  local resolved = vim.fn.resolve(dirname)
  -- Only return if the resolved path is an actual existing directory
  if vim.fn.isdirectory(resolved) == 1 then
    return resolved
  end
  return nil
end

--- Pipeline: _get_last_part → _match_path → _resolve_root.
--- Extracts and resolves a path from the cursor line.
--- @param self cmp_path.Source
--- @param line string  Text before cursor (cursor_before_line)
--- @param params cmp.SourceCompletionApiParams  Completion context
--- @param option cmp_path.Option  Validated source options
--- @return string|nil root  Absolute directory path to scan
--- @return string|nil input  Filename prefix typed after the last "/" (for filtering)
source._get_path_option = function(self, line, params, option)
  -- Step 1: extract the trailing segment that might be a path
  local part = self:_get_last_part(line)
  if not part or part == "" then return nil end

  -- Step 2: classify the segment into a path kind
  local pathstr, kind = self:_match_path(part)
  if not pathstr then return nil end

  -- Step 3: resolve the directory to scan
  local root = self:_resolve_root(pathstr, kind, params, option)
  if not root then return nil end

  -- The "input" is whatever comes after the last "/" — used for fuzzy filtering
  local input = pathstr:match("[^/]*$") or ""
  return root, input
end

--- Scan a directory and build nvim-cmp completion items.
--- Uses libuv's synchronous fs_scandir for simplicity (fast enough for typical dirs).
--- @param _ cmp_path.Source  (unused self)
--- @param dirname string  Absolute directory path to scan
--- @param include_hidden boolean  Whether to include dotfiles (names starting with ".")
--- @param option cmp_path.Option  Validated source options
--- @param callback fun(err: string|nil, items: lsp.CompletionItem[]|nil)  Results callback
source._candidates = function(_, dirname, include_hidden, option, callback)
  -- Open a directory scanner handle
  local fs, err = vim.uv.fs_scandir(dirname)
  if err then
    return callback(err, nil)
  end

  --- @type lsp.CompletionItem[]
  local items = {}
  while true do
    -- Advance to the next directory entry
    local name, fs_type, e = vim.uv.fs_scandir_next(fs)
    if e then
      return callback(e, nil)
    end
    -- nil name means we've exhausted all entries
    if not name then
      break
    end
    -- Skip hidden files unless explicitly requested (user typed ".")
    if not include_hidden and name:sub(1, 1) == "." then
      goto continue
    end

    local path = dirname .. "/" .. name
    -- stat() follows symlinks; gives us the real file type and size
    local stat = vim.uv.fs_stat(path)
    --- @type uv.uv_fs_t|nil
    local lstat = nil
    if stat then
      -- Use the resolved type from stat (more accurate than scandir's fs_type)
      fs_type = stat.type
    elseif fs_type == "link" then
      -- Broken symlink: stat failed but scandir reported "link"
      -- Use lstat to confirm the link itself exists
      lstat = vim.uv.fs_lstat(path)
      if not lstat then goto continue end
    else
      -- Cannot stat and not a symlink; skip this entry
      goto continue
    end

    --- @type lsp.CompletionItem
    local item = {
      label = name,                              -- Display text in popup
      filterText = name,                         -- Text nvim-cmp matches against
      insertText = name,                         -- Text inserted on confirm
      kind = cmp.lsp.CompletionItemKind.File,    -- Icon/category hint
      data = { path = path, type = fs_type, stat = stat, lstat = lstat },
    }
    if fs_type == "directory" then
      item.kind = cmp.lsp.CompletionItemKind.Folder
      -- Show trailing "/" on label for visual distinction (configurable)
      item.label = option.label_trailing_slash and (name .. "/") or name
      -- Always insert "/" after directory name to allow continuous completion
      item.insertText = name .. "/"
      -- When trailing_slash is false, set word to bare name so "/" doesn't
      -- appear in the completed text when the user accepts without continuing
      if not option.trailing_slash then
        item.word = name
      end
    end
    table.insert(items, item)

    ::continue::
  end

  -- Deliver all collected items (may be empty for an empty directory)
  callback(nil, items)
end

--- Validate and merge per-source options with defaults.
--- @param _ cmp_path.Source  (unused self)
--- @param params cmp.SourceCompletionApiParams  Completion context (contains .option)
--- @return cmp_path.Option  Validated and merged option table
source._validate_option = function(_, params)
  -- "keep" means user-provided values take precedence; defaults fill gaps
  local option = vim.tbl_deep_extend("keep", params.option or {}, defaults)
  vim.validate("trailing_slash", option.trailing_slash, "boolean")
  vim.validate("label_trailing_slash", option.label_trailing_slash, "boolean")
  vim.validate("get_cwd", option.get_cwd, "function")
  return option
end

--- Generate documentation content for a file (shown in the completion preview popup).
--- Reads the first 1KB of the file; if binary (contains null bytes), shows "binary file";
--- otherwise shows up to MAX_PREVIEW_LINES wrapped in a fenced code block.
--- @param _ cmp_path.Source  (unused self)
--- @param filename string  Absolute path to the file
--- @param count integer  Maximum number of lines to include
--- @return lsp.MarkupContent  Documentation content for nvim-cmp's preview window
source._get_documentation = function(_, filename, count)
  -- Read first 1KB in binary mode for null-byte detection
  local binary = assert(io.open(filename, "rb"))
  local first_kb = binary:read(1024)
  binary:close()
  -- Empty file: return empty documentation
  if not first_kb or first_kb == "" then
    return { kind = cmp.lsp.MarkupKind.PlainText, value = "" }
  end
  -- Null byte present: this is a binary file, don't try to render it
  if first_kb:find("\0") then
    return { kind = cmp.lsp.MarkupKind.PlainText, value = "binary file" }
  end

  -- Split the first KB into lines (handles both LF and CRLF)
  --- @type string[]
  local contents = {}
  for line in first_kb:gmatch("[^\r\n]+") do
    table.insert(contents, line)
    if #contents >= count then break end
  end

  -- Detect filetype for syntax-highlighted code fence
  local filetype = vim.filetype.match({ filename = filename })
  if not filetype then
    -- Unknown filetype: plain text without highlighting
    return { kind = cmp.lsp.MarkupKind.PlainText, value = table.concat(contents, "\n") }
  end

  -- Wrap in markdown fenced code block for syntax highlighting
  table.insert(contents, 1, "```" .. filetype)
  table.insert(contents, "```")
  return { kind = cmp.lsp.MarkupKind.Markdown, value = table.concat(contents, "\n") }
end

return source
