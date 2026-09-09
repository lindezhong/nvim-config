-- Custom filesystem path completion source for nvim-cmp.
--
-- As the user types a filesystem path into a buffer or the command line, the
-- entries of the directory it points at are offered as completions, with a
-- documentation preview of file contents.
--
-- Supported path kinds:
--   absolute:  /usr/local/bin/
--   relative:  ./src/  or  src/
--   parent:    ../lib/
--   home:      ~/docs/
--   drive:     C:/Users/   (treated as a drive root only on Windows)
-- A path is recognised anywhere in the line, including inside a colon-separated
-- list such as PATH=.:/usr/bin:/usr/li, where completion applies to the entry
-- after the nearest colon.  Environment variable references are expanded before
-- matching, in the POSIX shell forms $VAR and ${VAR} plus the cmd.exe form
-- %VAR%, so $HOME/docs and ${JAVA_HOME}/bin complete like plain absolute paths.
-- Filenames and directories containing spaces are handled with shell-style "\ "
-- escaping.

--- @type cmp  nvim-cmp core module (provides lsp.CompletionItemKind, lsp.MarkupKind)
local cmp = require("cmp")

--- @class cmp_path.Source  Custom nvim-cmp source for filesystem path completion.
local source = {}

--- Whether this is a Windows host.  The platform is consulted in four places,
--- all of them about drive/UNC path flavour or the backslash separator:
--- PATH_RE's "[a-zA-Z]:" drive-letter alternative, get_trigger_characters' "\"
--- auto-trigger, is_absolute's "C:\" and "\\" absolute forms, and _get_root's
--- drive-letter branch.  Everywhere else "/" and "\" are accepted interchangeably
--- regardless of platform, because a path typed into a buffer need not belong to
--- the machine editing it.
--- @type boolean
local IS_WINDOWS = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

--- Placeholder substituted for an environment variable reference that could not
--- be resolved.  Listed in INVALID_CHARS below so it also acts as a hard
--- boundary, and _get_path_option rejects the line outright when this is the
--- character immediately before the PATH_RE match — see _resolve_env_variables
--- for why leaving the reference in place would be a defect.
--- SOH rather than the more obvious NUL: the expanded line is handed to
--- vim.fn.matchlist(), and a Lua string containing a NUL reaches Vim as a Blob,
--- which raises E976.  Any control character outside PATH_CLASS will do.
--- @type string
local UNRESOLVED = "\1"

--- Characters that cannot appear in a path, used as hard boundaries when
--- scanning; UNRESOLVED is included so it bounds a match too.
--- Note what is *not* here: ":" and "\".  The colon boundary lives in PATH_RE's
--- character class instead, which is what splits a colon-separated path list
--- while still leaving room for a drive letter — see PATH_RE.
--- @type table<string, boolean>
local INVALID_CHARS = {
  ["#"] = true, ["<"] = true, ["+"] = true, ["$"] = true,
  ["%"] = true, [">"] = true, ["!"] = true, ["`"] = true,
  ["&"] = true, ["*"] = true, ["'"] = true, ["|"] = true,
  ["{"] = true, ["?"] = true, ['"'] = true, ["="] = true,
  ["}"] = true, ["@"] = true,
  [UNRESOLVED] = true,
}

--- Characters allowed in a path segment, as the body of a Vim regex collection.
--- Vim collections do not accept "\w", so its word characters are spelled out.
--- Written with "\uXXXX" escapes so this file stays pure ASCII — a literal U+00A0
--- here is invisible on screen, and if anything downgrades it to U+0020 the range
--- silently widens to U+0020-U+024F, which admits ":" and breaks the path-list
--- splitting PATH_RE relies on.  Keep "-" last in every collection built from
--- this, where it is literal.
--- @type string
local SEGMENT_CHARS = "\\u4e00-\\u9fa5\\u00a0-\\u024f0-9A-Za-z_.@()"

--- Collection matching one character of a path segment.  Includes a space,
--- which is why PATH_RE must be applied to a space-bounded slice of the line
--- rather than the whole line — see step 3 of _get_path_option.
--- @type string
local PATH_CLASS = "[" .. SEGMENT_CHARS .. " -]"

--- Collection for the *first* segment of a relative path, i.e. everything left
--- of the first separator in "lua/plu".  Same as PATH_CLASS minus the space.
--- It must admit CJK and accented names and dot directories: an ASCII-only "\w"
--- could not start a path with a CJK or accented name, nor with a dot directory,
--- so for "中文目录/x" and ".git/HEAD" the prefix would fail to match, and since
--- the regex is end-anchored the match would then slide right to the interior
--- separator and yield "/x" — a confidently wrong root of "/" rather than no
--- completion at all.
--- @type string
local BARE_CLASS = "[" .. SEGMENT_CHARS .. "-]"

--- The path recogniser: a prefix, a separator, then segments to end of string.
--- In PCRE notation the pattern is:
---   /(?:\.{0,2}|~|([\w]+)|[a-zA-Z]:|)(\/|\\+)
---    (?:[<class>]+(\/|\\+))*(?:[<class>])*$/
--- Read it right-to-left: the text must *end* in a path, so matching finds the
--- leftmost position from which everything up to the cursor is path-shaped.  No
--- leftward terminator scan is involved; a character absent from PATH_CLASS
--- (":", "=") bounds the match implicitly, which is what splits a path list.
--- Submatch 1 is the bare first segment ("lua" in "lua/plu"), which _get_root
--- probes for.
---
--- Three details each prevent a *wrong* directory from being reported:
---
--- 1. A negative lookbehind pins the left edge.  End-anchoring alone does not
---    fail when no prefix matches — it slides right to the next separator and
---    matches from there, so "http://exa" yields "/exa" and completes from "/",
---    and "/tmp/a//b" yields "/b".  Requiring that the character before the
---    match be neither a path character nor a separator removes both.  It must
---    be a zero-width assertion and not a hand-written byte test: PATH_CLASS
---    spans multi-byte characters, so inspecting the single preceding byte reads
---    a UTF-8 continuation byte and lets CJK through.
---
--- 2. BARE_CLASS, not an ASCII-only "\w", matches the first segment; see there.
---
--- 3. The "[a-zA-Z]:" drive-letter alternative is Windows-only, because _get_root
---    only ever consults a drive letter on Windows.  Enabling it everywhere would
---    mis-fire on the commonest shape of the very input this source exists to
---    handle:
---      PATH=/usr/bin:/usr/li
---    Matching leftmost-first, the "n" of "bin" is taken as a drive letter,
---    pathstr becomes "n:/usr/li", _get_root falls through to cwd, and the
---    non-existent "cwd/n:/usr" makes the whole line yield nothing.  Any list
---    entry ending in a letter triggers it, which is the usual shape.  Restricting
---    the alternative to Windows costs only "C:/Us" typed on Linux, which then
---    reads as the absolute "/Us" — meaningless input either way.
---
--- There is deliberately no "$"-prefixed alternative: step 1 expands every env
--- reference before matching and a bare "$" is in INVALID_CHARS, so no "$" can
--- reach this regex.  With no case-sensitive literal left in the pattern,
--- 'ignorecase' cannot change what matches, so no "\C" override is needed either.
--- @type string
local PATH_RE = [[\%(]] .. PATH_CLASS .. [[\|[/\\]\)\@<!]]
  .. [[\%(\.\{0,2}\|\~\|\(]] .. BARE_CLASS .. [[\+\)]]
  .. (IS_WINDOWS and [[\|[a-zA-Z]:]] or "")
  .. [[\|\)\%(/\|\\\+\)]]
  .. [[\%(]] .. PATH_CLASS .. [[\+\%(/\|\\\+\)\)*\%(]] .. PATH_CLASS .. [[\)*$]]

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
--- "\" is offered only on Windows — one of the few places that consult the
--- platform (see IS_WINDOWS).  Parsing still accepts "\" everywhere; this only
--- controls *auto*-triggering, where a backslash on a POSIX host is far more
--- often an escape than a separator.
--- @return string[]
source.get_trigger_characters = function()
  if IS_WINDOWS then
    return { "/", ".", "\\" }
  end
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
  -- 0-based byte column of cursor: equal to the byte length of the text before it
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

--- Expand every environment variable reference in the text, in three forms:
--- %VAR%, ${VAR} and $VAR.  Runs before any path parsing, so later steps only
--- ever see literal paths.
---
--- A single left-to-right walk rather than one gsub per form.  Substituted text
--- is appended to the output and never revisited, so a value that happens to
--- contain a "$" or a "%" cannot be expanded a second time.
---
--- A reference to an unset or empty variable becomes the UNRESOLVED placeholder
--- rather than being left in place.  Leaving it would let the variable *name*
--- survive as literal path text — "$lua/plu" would read as the relative path
--- "lua/plu" and complete, from a real directory the user never named.
--- @param _ cmp_path.Source  (unused self)
--- @param text string  The text to expand (typically cursor_before_line)
--- @return string  The text with references replaced by values or UNRESOLVED
source._resolve_env_variables = function(_, text)
  local out, i = {}, 1
  while true do
    local sigil = text:find("[%%$]", i)
    if not sigil then break end
    table.insert(out, text:sub(i, sigil - 1))

    --- @type string|nil, integer|nil
    local name, after
    if text:sub(sigil, sigil) == "%" then
      -- %VAR%: anything between two percent signs, as in cmd.exe
      local close = text:find("%%", sigil + 1)
      if close and close > sigil + 1 then
        name, after = text:sub(sigil + 1, close - 1), close + 1
      end
    elseif text:sub(sigil + 1, sigil + 1) == "{" then
      local close = text:find("}", sigil + 2, true)
      if close and close > sigil + 2 then
        name, after = text:sub(sigil + 2, close - 1), close + 1
      end
    else
      -- $VAR: a name that does not start with a digit
      local n, stop = text:match("^([%a_][%w_]*)()", sigil + 1)
      name, after = n, stop
    end

    if name then
      local value = vim.fn.getenv(name)
      -- getenv() yields vim.NIL for an unset variable, and never errors even on
      -- a name that could not legally be exported
      table.insert(out, (value == vim.NIL or value == "") and UNRESOLVED or value)
      i = after
    else
      -- Not a reference after all, so the sigil is ordinary text
      table.insert(out, text:sub(sigil, sigil))
      i = sigil + 1
    end
  end
  table.insert(out, text:sub(i))
  return table.concat(out)
end

--- Scan the text backwards for the rightmost run of path-legal characters,
--- stopping at any INVALID_CHARS character or an unescaped space.
---
--- This does *not* classify the path — PATH_RE does.  Its two jobs are to bound
--- the subject PATH_RE is matched against (step 3 of _get_path_option) and to
--- reject a tail ending in a separator pair.  Note that the separator-pair check
--- stops "http://" only at the moment the second slash is typed; what keeps
--- "http://exa" from completing one keystroke later is PATH_RE's lookbehind, not
--- this.
---
--- We call it a second time, on the *un*expanded line, to recover the text the
--- user literally typed; see step 5 of _get_path_option.
--- @param _ cmp_path.Source  (unused self)
--- @param text string  The text to scan
--- @return string  The trailing run of path-legal characters ("" if none)
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

--- Locate the trailing path in the text by matching PATH_RE.
--- @param _ cmp_path.Source  (unused self)
--- @param text string  The text to search
--- @return string|nil pathstr  The matched path text
--- @return string|nil part  Submatch 1: the bare first segment, "" if absent
--- @return integer|nil start  0-based byte offset where the match begins
source._match_path = function(_, text)
  local groups = vim.fn.matchlist(text, PATH_RE)
  local pathstr = groups[1]
  if not pathstr or pathstr == "" then return nil end
  -- PATH_RE ends in "$", so the match always runs to the end of the text and its
  -- start follows from the lengths.  matchlist() reports a group that did not
  -- participate as "", which is the value we want for part.
  return pathstr, groups[2] or "", #text - #pathstr
end

--- Whether pathstr is rooted, and so needs no base directory prepended.
--- Recognises a leading "/" everywhere, plus the two Windows-only forms a drive
--- path can take.  A single leading "\" is deliberately not accepted: that form
--- cannot reach here, because PATH_RE only produces a backslash-led match for a
--- UNC path.
--- @param pathstr string
--- @return boolean
local function is_absolute(pathstr)
  if IS_WINDOWS and (pathstr:match("^%a:[/\\]") or pathstr:match("^[/\\][/\\]")) then
    return true
  end
  return pathstr:sub(1, 1) == "/"
end

--- Whether path names an existing directory.
--- @param path string
--- @return boolean
local function is_dir(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

--- Determine the base directory a *relative* pathstr resolves against.
--- The rooted branches are inert, since _get_directory ignores the root for
--- anything is_absolute accepts.
---
--- When the bare-segment branch finds that neither candidate directory exists it
--- returns nil, so the caller declines outright rather than resolving against a
--- non-existent root.
--- @param _ cmp_path.Source  (unused self)
--- @param pathstr string  The path text from _match_path
--- @param part string  Submatch 1 from _match_path: the bare first segment
--- @param buf_dirname string  Directory of the buffer being completed in
--- @param cwd string  Current working directory
--- @return string|nil  Base directory, or nil if no plausible one exists
source._get_root = function(_, pathstr, part, buf_dirname, cwd)
  -- "./x", "../x" and ".git/x" are relative to the buffer, falling back to cwd
  if pathstr:sub(1, 1) == "." then
    return buf_dirname ~= "" and buf_dirname or cwd
  end

  -- "C:/x" is a drive path only where drives exist.  Off Windows PATH_RE never
  -- produces one, so this branch is simply unreachable there.
  if IS_WINDOWS and pathstr:match("^%w+:") then
    return pathstr:match("[/\\]$") and pathstr or vim.fn.fnamemodify(pathstr, ":h")
  end

  if not IS_WINDOWS and pathstr:sub(1, 1) == "/" then
    return pathstr:sub(-1) == "/" and pathstr or vim.fn.fnamemodify(pathstr, ":h")
  end

  -- Bare first segment, as in "lua/plu": accept the path as relative only if that
  -- segment really is a directory, next to the buffer or under cwd.  This is the
  -- test that keeps "on 12/25" and "a/b" from completing.  A *file* of the same
  -- name must not count, or it would win here and block the cwd fallback.
  if part ~= "" then
    if buf_dirname ~= "" and is_dir(vim.fs.joinpath(buf_dirname, part)) then
      return buf_dirname
    end
    if is_dir(vim.fs.joinpath(cwd, part)) then
      return cwd
    end
    return nil
  end

  return cwd
end

--- Reduce pathstr to the directory whose entries should be offered.
--- @param _ cmp_path.Source  (unused self)
--- @param pathstr string  The path text from _match_path
--- @param root string  Base directory from _get_root
--- @return string  Directory path, not yet checked for existence
source._get_directory = function(_, pathstr, root)
  -- A trailing separator means the user is inside that directory already;
  -- otherwise the tail is a partial name, so strip it
  local dir_part = pathstr:match("[/\\]$") and pathstr or vim.fn.fnamemodify(pathstr, ":h")
  if is_absolute(pathstr) then
    return dir_part
  end
  -- normalize() collapses the "/./" and "/../" a relative part leaves behind.
  -- expand_env is off because a directory really named "$foo" must survive;
  -- nothing here is meant to be expanded twice.
  return vim.fs.normalize(vim.fs.joinpath(root, dir_part), { expand_env = false })
end

--- Extract and resolve a path from the cursor line, returning the directory to
--- scan and the filename prefix typed after the last separator.
--- @param self cmp_path.Source
--- @param line string  Text before cursor (cursor_before_line)
--- @param params cmp.SourceCompletionApiParams  Completion context
--- @param option cmp_path.Option  Validated source options
--- @return string|nil root  Absolute directory path to scan
--- @return string|nil input  Filename prefix typed after the last separator
source._get_path_option = function(self, line, params, option)
  -- Step 1: expand $VAR / ${VAR} / %VAR% across the whole line, so the steps
  -- below only ever deal with literal paths
  local expanded_line = self:_resolve_env_variables(line)

  -- Step 2: isolate the trailing run of path-legal characters.  A trailing
  -- separator pair is rejected outright: it is the one shape whose own left edge
  -- is a separator, so PATH_RE's lookbehind cannot judge it.
  local guard = self:_get_last_part(expanded_line)
  if guard == "" then return nil end
  if guard:sub(-2) == "//" or guard:sub(-2) == "\\\\" then return nil end

  -- Step 3: locate the path inside that run.  PATH_RE is matched against guard,
  -- the space-bounded slice, not the whole line: PATH_CLASS contains a space, so
  -- matching the whole line would let one path swallow the one before it — a
  -- line-leading "/etc/hosts /tmp/f" matches whole, _get_directory then takes the
  -- head "/etc/hosts /tmp", finds no such directory and offers nothing.  (A
  -- command prefix such as "cp /etc/hosts /tmp/f" does not swallow: the space
  -- before "/etc" is itself in PATH_CLASS, so the lookbehind vetoes that start and
  -- the whole line simply fails to match.)  guard is bounded at the first
  -- unescaped space, so neither shape reaches here.
  local pathstr, part, start = self:_match_path(guard)
  if not pathstr then return nil end

  -- An unresolved variable reference sitting immediately before the match means
  -- the path is rooted in something we could not expand, so whatever we resolved
  -- would point somewhere the user did not name.  Declining beats guessing; see
  -- _resolve_env_variables.  UNRESOLVED is in INVALID_CHARS, so it can only ever
  -- be the character just before guard, never inside it.
  local guard_start = #expanded_line - #guard
  if start == 0 and guard_start >= 1
    and expanded_line:sub(guard_start, guard_start) == UNRESOLVED
  then
    return nil
  end

  -- After step 1 the only thing left to expand is a leading "~", and it is
  -- expanded by hand rather than through vim.fn.expand(), which would also act on
  -- wildcards and on the "%" / "#" specials that happen to be sitting in this
  -- text.
  if pathstr:sub(1, 1) == "~" then
    pathstr = vim.fn.expand("~") .. pathstr:sub(2)
  end

  -- Restore real spaces before any filesystem access.  The buffer carries the
  -- shell-escaped "\ " — _get_last_part keeps it intact and PATH_RE matches it —
  -- but a directory named "1 2" is "1 2" on disk, not "1\ 2", so every path built
  -- below (_get_root's probes, _get_directory, isdirectory, the scan) needs the
  -- literal space.  Only "\ " pairs are touched, so a Windows separator like the
  -- "\" in "C:\Users" is left alone.  The Step 5 input is read from the original
  -- line and stays escaped: it sizes a textEdit range against raw buffer bytes,
  -- and _candidates emits the same escaped form so the two round-trip.
  --
  -- Known edge: this round-trip only covers absolute paths and the trailing
  -- segments of relative ones.  A relative path whose *first* segment holds an
  -- escaped space — "my\ dir/fi" — is split by PATH_RE on the backslash into
  -- part="my", so _get_root probes a "my" that does not exist and declines.
  -- Absolute "/my\ dir/fi" is unaffected (it never uses part).  Escaping the
  -- whole leading path or using an absolute one both work.
  pathstr = pathstr:gsub("\\ ", " ")
  part = part:gsub("\\ ", " ")

  -- Step 4: resolve the base directory (_get_root), then the directory to scan
  -- (_get_directory)
  local buf_dirname = option.get_cwd(params)
  local cwd = vim.fn.getcwd()
  -- On the command line there is no meaningful "buffer directory"
  if vim.api.nvim_get_mode().mode == "c" then
    buf_dirname = cwd
  end
  local root = self:_get_root(pathstr, part, buf_dirname, cwd)
  if not root then return nil end

  local resolved = vim.fn.resolve(self:_get_directory(pathstr, root))
  if vim.fn.isdirectory(resolved) ~= 1 then return nil end

  -- Step 5: take the "input" (text after the last separator, used both for fuzzy
  -- filtering and for sizing the caller's textEdit range) from the *original*
  -- line, never from the expanded one.  The range is applied to the real buffer
  -- line, so input must be text the user literally typed.
  --
  -- Scanning the original line is enough to guarantee that.  "$", "%", "{" and
  -- "}" are all in INVALID_CHARS, so the tail _get_last_part returns can never
  -- contain a variable reference; requiring a separator inside it then proves the
  -- separator ahead of the input was typed literally too.  A bare "$HOME" with
  -- no typed "/" has no such separator and is rejected here — as is "$nvim",
  -- where the expanded tail happens to equal the variable name and a plain
  -- string comparison against the line would have been fooled.
  local typed = self:_get_last_part(line)
  local sep = self:_last_separator(typed)
  if not sep then return nil end

  return resolved, typed:sub(sep + 1)
end

--- Byte index of the last path separator in text, or nil if it has none.
--- A backslash that escapes a space is not a separator: _get_last_part keeps
--- "my\ file" in one piece precisely so the space stays part of the name, and
--- treating the backslash as a separator here would contradict it — the input
--- would come back as " file", and since the caller sizes its replace range from
--- the input's length, accepting a candidate would corrupt the line.
--- @param _ cmp_path.Source  (unused self)
--- @param text string
--- @return integer|nil
source._last_separator = function(_, text)
  for i = #text, 1, -1 do
    local ch = text:sub(i, i)
    if ch == "/" or (ch == "\\" and text:sub(i + 1, i + 1) ~= " ") then
      return i
    end
  end
  return nil
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

    -- joinpath rather than concatenation: dirname is "/" for a root-level path,
    -- and "//name" is a UNC prefix on Windows
    local path = vim.fs.joinpath(dirname, name)
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

    -- Shell-escape spaces in every field the user sees or that lands in the
    -- buffer.  nvim-cmp matches the literal buffer text (which the user types as
    -- "my\ file") against filterText, and on confirm replaces the range with
    -- textEdit.newText (= insertText) verbatim — an unescaped space there would
    -- read back as a path terminator and break continuation.  _get_path_option
    -- restores the real space before touching the filesystem, so the two sides
    -- round-trip.  data.path stays raw: it is a real filesystem path used by
    -- resolve() for the preview.
    local display = name:gsub(" ", "\\ ")

    --- @type lsp.CompletionItem
    local item = {
      label = display,                           -- Display text in popup
      filterText = display,                      -- Text nvim-cmp matches against
      insertText = display,                      -- Text inserted on confirm
      kind = cmp.lsp.CompletionItemKind.File,    -- Icon/category hint
      data = { path = path, type = fs_type, stat = stat, lstat = lstat },
    }
    if fs_type == "directory" then
      item.kind = cmp.lsp.CompletionItemKind.Folder
      -- Show trailing "/" on label for visual distinction (configurable)
      item.label = option.label_trailing_slash and (display .. "/") or display
      -- Always insert "/" after directory name to allow continuous completion
      item.insertText = display .. "/"
      -- When trailing_slash is false, set word to bare name so "/" doesn't
      -- appear in the completed text when the user accepts without continuing
      if not option.trailing_slash then
        item.word = display
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
