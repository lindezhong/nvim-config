-- Git operations library for Neovim.
-- Provides functions to interact with git via shell commands, including status,
-- diff, log, blame, and file content retrieval. All functions return structured
-- Lua tables parsed from git's porcelain/machine-readable output formats.

--- @type table
local M = {}

---@class GitFile
---@field path string        -- Relative file path in the repository
---@field status string      -- Single-character git status code (M, A, D, R, ?, etc.)
---@field staged boolean     -- Whether the change is staged in the index
---@field renamed_from string?  -- Original path if file was renamed/copied

---@class GitCommit
---@field hash string       -- Abbreviated commit hash
---@field hash_full string  -- Full-length commit hash
---@field author string     -- Author name
---@field date string       -- Commit date (short format)
---@field message string    -- Commit subject line

---@class GitBlameLine
---@field hash string       -- Commit hash for this line
---@field author string     -- Author who last modified this line
---@field date string       -- Date of last modification
---@field line_number integer -- Line number in the current file
---@field content string    -- Actual text content of the line

--- Execute a git command synchronously and return stdout on success.
--- @param cmd string[] List of command arguments to pass to vim.system
--- @return string|nil stdout Output text on success, nil on failure
--- @return string|nil err Error message on failure, nil on success
local function run(cmd)
  -- Run the command synchronously with text mode enabled
  local result = vim.system(cmd, { text = true }):wait()
  -- Return nil and the error message if the command failed
  if result.code ~= 0 then
    return nil, result.stderr or ""
  end
  -- Return stdout on success
  return result.stdout or "", nil
end

--- Split a string into an array of lines (splitting on newline characters).
--- @param str string|nil The input string to split
--- @return string[] lines Array of non-empty lines
local function lines(str)
  -- Return empty table if input is nil or empty
  if not str or str == "" then
    return {}
  end
  local result = {}
  -- Match sequences of characters that are not newlines
  for line in str:gmatch("[^\n]+") do
    result[#result + 1] = line
  end
  return result
end

--- Get the root directory of the current git repository.
--- @return string|nil root Absolute path to git repo root, or nil if not in a repo
local function git_root()
  -- Run git rev-parse to find the repository toplevel directory
  local out = run({ "git", "rev-parse", "--show-toplevel" })
  if out then
    -- Strip trailing whitespace/newline from the output
    return out:gsub("%s+$", "")
  end
  return nil
end

--- Get the working tree status (staged and unstaged changes).
--- Parses `git status --porcelain=v1 -z` output into structured file entries.
--- @return GitFile[] files List of files with their status information
function M.status()
  -- Run git status with NUL-separated porcelain output including untracked files
  local out, err = run({ "git", "status", "--porcelain=v1", "-z", "--untracked-files=all" })
  -- Return empty list if the command failed
  if not out then
    return {}
  end
  local files = {}
  -- Split on NUL byte to get individual status entries
  local entries = vim.split(out, "\0", { trimempty = true })
  local i = 1
  while i <= #entries do
    local entry = entries[i]
    -- Skip entries that are too short to contain valid status info
    if #entry < 4 then
      i = i + 1
      goto continue
    end
    -- Extract the index status character (X) from position 1
    local x = entry:sub(1, 1)
    -- Extract the worktree status character (Y) from position 2
    local y = entry:sub(2, 2)
    -- Extract the file path starting from position 4, removing trailing slash
    local path = entry:sub(4):gsub("/$", "")
    local renamed_from = nil
    -- For renamed files, the next entry contains the original path
    if x == "R" or y == "R" then
      i = i + 1
      renamed_from = entries[i]
    end
    -- Record staged changes (X column, ignoring spaces and untracked markers)
    if x ~= " " and x ~= "?" then
      files[#files + 1] = {
        path = path,
        status = x,
        staged = true,
        renamed_from = renamed_from,
      }
    end
    -- Record unstaged/worktree changes (Y column, ignoring spaces)
    if y ~= " " then
      -- Normalize untracked marker to "?"
      local status = y == "?" and "?" or y
      files[#files + 1] = {
        path = path,
        status = status,
        staged = false,
        renamed_from = nil,
      }
    end
    i = i + 1
    ::continue::
  end
  return files
end

---@class DiffFilesOpts
---@field ref1 string?     -- First reference (e.g., commit hash or branch name)
---@field ref2 string?     -- Second reference to compare against
---@field cached boolean?  -- If true, show staged changes (index vs HEAD)
---@field path string?     -- Limit diff to a specific file path

--- Get the list of files changed between two refs or in the working tree.
--- @param opts DiffFilesOpts? Options controlling the diff comparison
--- @return GitFile[] files List of changed files with their status
function M.diff_files(opts)
  opts = opts or {}
  -- Build the git diff command with --name-status for file status and -z for NUL separation
  local cmd = { "git", "diff", "--name-status", "-z" }
  -- Add --cached flag to compare index against HEAD
  if opts.cached then
    cmd[#cmd + 1] = "--cached"
  end
  -- Add first reference if provided
  if opts.ref1 then
    cmd[#cmd + 1] = opts.ref1
  end
  -- Add second reference if provided
  if opts.ref2 then
    cmd[#cmd + 1] = opts.ref2
  end
  -- Add path filter after the "--" separator
  if opts.path then
    cmd[#cmd + 1] = "--"
    cmd[#cmd + 1] = opts.path
  end
  local out = run(cmd)
  -- Return empty list if the command failed
  if not out then
    return {}
  end
  -- Split on NUL byte to parse status/path pairs
  local parts = vim.split(out, "\0", { trimempty = true })
  local files = {}
  local i = 1
  while i <= #parts do
    -- Extract the status character from the current part
    local status_str = parts[i]
    local status = status_str:sub(1, 1)
    i = i + 1
    -- The next part is the file path
    local path = parts[i]
    i = i + 1
    local renamed_from = nil
    -- For renames and copies, there is an extra path entry (source path)
    if status == "R" or status == "C" then
      renamed_from = path
      path = parts[i]
      i = i + 1
    end
    -- Add the file entry if path is valid
    if path then
      files[#files + 1] = {
        path = path,
        status = status,
        staged = false,
        renamed_from = renamed_from,
      }
    end
  end
  return files
end

--- Retrieve the content of a file at a specific git revision.
--- @param rev string Git revision (commit hash, branch, tag, etc.)
--- @param path string File path relative to repository root
--- @return string[]|nil lines Array of lines, or nil if the file cannot be read
function M.file_content(rev, path)
  -- Use git show to retrieve the file at the specified revision
  local out = run({ "git", "show", rev .. ":" .. path })
  if not out then
    return nil
  end
  -- Split into lines, preserving empty lines (no trimempty)
  return vim.split(out, "\n", { trimempty = false })
end

---@class DiffContentOpts
---@field ref1 string?     -- First reference for the diff
---@field ref2 string?     -- Second reference for the diff
---@field cached boolean?  -- If true, show staged diff
---@field path string      -- File path to diff (required)

--- Get the unified diff content for a specific file.
--- @param opts DiffContentOpts Options specifying what to diff
--- @return string[] lines Array of diff output lines
function M.diff_content(opts)
  -- Build the git diff command
  local cmd = { "git", "diff" }
  -- Add --cached to diff the index against HEAD
  if opts.cached then
    cmd[#cmd + 1] = "--cached"
  end
  -- Add first reference if provided
  if opts.ref1 then
    cmd[#cmd + 1] = opts.ref1
  end
  -- Add second reference if provided
  if opts.ref2 then
    cmd[#cmd + 1] = opts.ref2
  end
  -- Add the file path after the "--" separator
  cmd[#cmd + 1] = "--"
  cmd[#cmd + 1] = opts.path
  local out = run(cmd)
  -- Return empty list if the command failed
  if not out then
    return {}
  end
  -- Split into lines, preserving empty lines for proper diff display
  return vim.split(out, "\n", { trimempty = false })
end

---@class LogOpts
---@field path string?    -- Limit log to a specific file path
---@field count number?   -- Maximum number of commits to return
---@field author string?  -- Filter commits by author name

--- Get the commit log with abbreviated information.
--- Uses NUL-delimited format for reliable parsing of commit fields.
--- @param opts LogOpts? Options to filter the log output
--- @return GitCommit[] commits List of commit records
function M.log(opts)
  opts = opts or {}
  -- Format: short_hash NUL full_hash NUL author NUL date NUL subject
  local cmd = { "git", "log", "--format=%h%x00%H%x00%an%x00%ad%x00%s", "--date=short" }
  -- Limit the number of commits returned
  if opts.count then
    cmd[#cmd + 1] = "-n"
    cmd[#cmd + 1] = tostring(opts.count)
  end
  -- Filter by author name pattern
  if opts.author then
    cmd[#cmd + 1] = "--author=" .. opts.author
  end
  -- Limit to commits touching a specific file
  if opts.path then
    cmd[#cmd + 1] = "--"
    cmd[#cmd + 1] = opts.path
  end
  local out = run(cmd)
  -- Return empty list if the command failed
  if not out then
    return {}
  end
  local commits = {}
  -- Parse each line (one commit per line) by splitting on NUL bytes
  for _, line in ipairs(lines(out)) do
    local parts = vim.split(line, "\0")
    -- Only include entries that have all 5 expected fields
    if #parts >= 5 then
      commits[#commits + 1] = {
        hash = parts[1],
        hash_full = parts[2],
        author = parts[3],
        date = parts[4],
        message = parts[5],
      }
    end
  end
  return commits
end

---@class GitCommitFull
---@field hash string    -- Full commit hash
---@field author string  -- Author name and email (e.g., "Name <email>")
---@field date string    -- Commit date in ISO format
---@field subject string -- Commit subject (first line of message)
---@field body string    -- Commit body (remaining lines of message)

--- Get the full commit log with complete message bodies.
--- Uses SOH (\x01) as record separator and NUL as field separator.
--- @param opts LogOpts? Options to filter the log output
--- @return GitCommitFull[] commits List of full commit records
function M.log_full(opts)
  opts = opts or {}
  -- Format: SOH hash NUL author<email> NUL date NUL subject NUL body
  local cmd = { "git", "log", "--format=%x01%H%x00%an <%ae>%x00%ad%x00%s%x00%b", "--date=iso" }
  -- Limit the number of commits returned
  if opts.count then
    cmd[#cmd + 1] = "-n"
    cmd[#cmd + 1] = tostring(opts.count)
  end
  -- Filter by author name pattern
  if opts.author then
    cmd[#cmd + 1] = "--author=" .. opts.author
  end
  -- Limit to commits touching a specific file
  if opts.path then
    cmd[#cmd + 1] = "--"
    cmd[#cmd + 1] = opts.path
  end
  local out = run(cmd)
  -- Return empty list if the command failed
  if not out then
    return {}
  end
  local commits = {}
  -- Split on SOH character to separate individual commit blocks
  local blocks = vim.split(out, "\x01", { trimempty = true })
  for _, block in ipairs(blocks) do
    -- Split each block on NUL to extract fields
    local parts = vim.split(block, "\0", { plain = true })
    -- Require at least 4 fields (hash, author, date, subject)
    if #parts >= 4 then
      -- Body is optional (5th field); strip trailing whitespace
      local body = (parts[5] or ""):gsub("%s+$", "")
      commits[#commits + 1] = {
        hash = parts[1],
        author = parts[2],
        date = parts[3],
        subject = parts[4],
        body = body,
      }
    end
  end
  return commits
end

--- Get the list of files changed in a specific commit.
--- Uses git diff-tree with NUL separation and --root to include the initial commit.
--- @param hash string Commit hash to inspect
--- @return GitFile[] files List of files changed in the commit
function M.commit_files(hash)
  -- Use diff-tree with --root to handle the initial commit, -r for recursive, -z for NUL separation
  local out = run({ "git", "diff-tree", "--no-commit-id", "--root", "-r", "--name-status", "-z", hash })
  -- Return empty list if the command failed
  if not out then
    return {}
  end
  -- Split on NUL byte to parse status/path pairs
  local parts = vim.split(out, "\0", { trimempty = true })
  local files = {}
  local i = 1
  while i <= #parts do
    -- Extract the single-character status code
    local status = parts[i]:sub(1, 1)
    i = i + 1
    -- Next part is the file path
    local path = parts[i]
    i = i + 1
    local renamed_from = nil
    -- For renames/copies, consume the extra source path entry
    if status == "R" or status == "C" then
      renamed_from = path
      path = parts[i]
      i = i + 1
    end
    -- Add file entry if the path is valid
    if path then
      files[#files + 1] = {
        path = path,
        status = status,
        staged = false,
        renamed_from = renamed_from,
      }
    end
  end
  return files
end

--- Show a commit's stat and patch output.
--- @param hash string Commit hash to display
--- @return string[] lines Array of output lines (stat + patch)
function M.show(hash)
  -- Use git show with --stat for diffstat and --patch for the full diff
  local out = run({ "git", "show", "--stat", "--patch", hash })
  -- Return empty list if the command failed
  if not out then
    return {}
  end
  -- Split into lines, preserving empty lines for formatting
  return vim.split(out, "\n", { trimempty = false })
end

---@class BlameOpts
---@field path string              -- File path to blame (required)
---@field ignore_whitespace boolean? -- If true, ignore whitespace changes (-w flag)
---@field date string?             -- Date format: "short" (YYYY-MM-DD) or "relative"
---@field contents string?         -- If set, blame using this content via stdin

--- Run git blame on a file and parse the porcelain output.
--- Supports blaming the current buffer contents (not yet committed) via the
--- --contents flag, and configurable date formatting (short or relative).
--- @param opts BlameOpts Options controlling the blame operation
--- @return GitBlameLine[] entries List of blame entries, one per line
function M.blame(opts)
  -- Build the git blame command with porcelain output for machine parsing
  local cmd = { "git", "blame", "--porcelain" }
  -- Add -w flag to ignore whitespace when determining blame
  if opts.ignore_whitespace then
    cmd[#cmd + 1] = "-w"
  end
  -- Use --contents - to read file content from stdin
  if opts.contents then
    cmd[#cmd + 1] = "--contents"
    cmd[#cmd + 1] = "-"
  end
  -- Add the file path to blame
  cmd[#cmd + 1] = opts.path
  -- Configure system command options, providing stdin if contents were specified
  local sys_opts = { text = true }
  if opts.contents then
    sys_opts.stdin = opts.contents
  end
  -- Execute the blame command
  local result = vim.system(cmd, sys_opts):wait()
  -- Return empty list if the command failed
  if result.code ~= 0 then
    return {}
  end
  local out = result.stdout or ""

  -- Determine the date format to use (default: "short")
  local date_format = opts.date or "short"

  --- Format a Unix timestamp according to the configured date format.
  --- @param ts number Unix timestamp
  --- @return string formatted_date Human-readable date string
  local function format_time(ts)
    if date_format == "relative" then
      -- Calculate seconds elapsed since the timestamp
      local diff = os.time() - ts
      -- Return appropriate relative time string based on the time difference
      if diff < 60 then return "just now"
      elseif diff < 3600 then
        local n = math.floor(diff / 60)
        return n == 1 and "1 min ago" or n .. " mins ago"
      elseif diff < 86400 then
        local n = math.floor(diff / 3600)
        return n == 1 and "1 hour ago" or n .. " hours ago"
      elseif diff < 2592000 then
        local n = math.floor(diff / 86400)
        return n == 1 and "1 day ago" or n .. " days ago"
      elseif diff < 31536000 then
        local n = math.floor(diff / 2592000)
        return n == 1 and "1 month ago" or n .. " months ago"
      else
        local n = math.floor(diff / 31536000)
        return n == 1 and "1 year ago" or n .. " years ago"
      end
    else
      -- Return ISO short date format (YYYY-MM-DD)
      return os.date("%Y-%m-%d", ts)
    end
  end

  --- @type GitBlameLine[]
  local entries = {}
  --- @type table Current blame entry being parsed
  local current = {}
  --- @type table<string, {author: string, date: string}> Cache of commit info by hash
  local seen = {}
  -- Parse the porcelain blame output line by line
  for _, line in ipairs(lines(out)) do
    -- Header line: hash original_line final_line [num_lines]
    if line:match("^%x+%s+%d+%s+%d+") then
      local hash, _, final_line = line:match("^(%x+)%s+(%d+)%s+(%d+)")
      -- Start a new blame entry with the hash and line number
      current = { hash = hash, line_number = tonumber(final_line) }
    elseif line:match("^author ") then
      -- Extract author name (everything after "author ")
      current.author = line:sub(8)
    elseif line:match("^author%-time ") then
      -- Extract and format the author timestamp
      local ts = tonumber(line:sub(13))
      if ts then
        current.date = format_time(ts)
      end
    elseif line:match("^\t") then
      -- Content line (starts with tab): marks end of this entry's metadata
      current.content = line:sub(2)
      local hash = current.hash
      -- Cache author info the first time we see a commit hash
      if current.author then
        seen[hash] = { author = current.author, date = current.date or "" }
      end
      -- Look up cached info for this hash (handles subsequent lines from same commit)
      local info = seen[hash] or {}
      -- Add the completed blame entry
      entries[#entries + 1] = {
        hash = hash,
        author = info.author or "",
        date = info.date or "",
        line_number = current.line_number or 0,
        content = current.content or "",
      }
    end
  end
  return entries
end

--- Expose git_root as a public function on the module.
--- @type fun(): string|nil
M.root = git_root

return M
