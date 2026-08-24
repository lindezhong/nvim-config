-- Git command dispatcher module.
-- Implements the :Git user command by parsing subcommands and their arguments,
-- then dispatching to the appropriate handler (status, diff, log, blame).
-- Also provides tab-completion for subcommands, flags, and commit refs.

--- @type table Module table for command operations
local M = {}

--- Parse a list of argument strings into a structured params table.
-- Supports the following argument formats:
--   --key=value  (long option with value)
--   --key        (long boolean flag)
--   -x value     (short option with next arg as value, if next arg is not a flag)
--   -x           (short boolean flag)
--   positional   (anything else is added to the positional list)
---@param args string[] Array of raw argument strings to parse
---@return table params Parsed parameters with named keys and a `positional` array
local function parse_args(args)
  -- Initialize params table with an empty positional arguments list
  local params = { positional = {} }
  local i = 1
  -- Iterate through all argument strings
  while i <= #args do
    local arg = args[i]
    if arg:match("^%-%-(.+)=(.+)$") then
      -- Handle --key=value format: extract key and value
      local key, val = arg:match("^%-%-(.+)=(.+)$")
      params[key] = val
    elseif arg:match("^%-%-") then
      -- Handle --key format: set as boolean true
      local key = arg:match("^%-%-(.+)$")
      params[key] = true
    elseif arg:match("^%-(%a)$") and args[i + 1] and not args[i + 1]:match("^%-") then
      -- Handle -x value format: short flag followed by non-flag value
      params[arg:sub(2)] = args[i + 1]
      -- Skip the next argument since it was consumed as the value
      i = i + 1
    elseif arg:match("^%-(%a)$") then
      -- Handle -x format: short boolean flag (no following value)
      params[arg:sub(2)] = true
    else
      -- Anything else is a positional argument (e.g., commit refs, file paths)
      table.insert(params.positional, arg)
    end
    -- Advance to the next argument
    i = i + 1
  end
  return params
end

--- Execute a :Git command by parsing the arguments string and dispatching
-- to the appropriate subcommand handler.
---@param args_str string The raw arguments string passed to the :Git command
function M.execute(args_str)
  -- Split the argument string on whitespace into individual tokens
  local args = vim.split(args_str, "%s+", { trimempty = true })
  -- Do nothing if no arguments were provided
  if #args == 0 then
    return
  end

  -- Extract the subcommand (first positional arg) from the args list
  local subcmd = table.remove(args, 1)
  -- Parse remaining args into structured parameters
  local params = parse_args(args)
  -- Get positional arguments (commit refs, file paths, etc.)
  local refs = params.positional

  if subcmd == "status" then
    -- Open the git status view; --unified flag switches to unified diff mode
    require("plugins.git.diff").status({
      mode = params.unified and "unified" or "vimdiff",
    })
  elseif subcmd == "diff" then
    -- Parse ref arguments for diff comparison
    local ref1, ref2
    if #refs == 1 then
      -- Single ref: check if it contains ".." for a range (e.g., "HEAD~3..HEAD")
      if refs[1]:find("%.%.") then
        ref1, ref2 = refs[1]:match("^(.+)%.%.(.+)$")
      else
        -- Single ref without range: compare that ref against working tree
        ref1 = refs[1]
      end
    elseif #refs == 2 then
      -- Two refs: explicit from/to comparison
      ref1, ref2 = refs[1], refs[2]
    end
    -- Open the diff view with parsed options
    require("plugins.git.diff").open({
      ref1 = ref1,                                                    -- base ref for comparison
      ref2 = ref2,                                                    -- target ref for comparison
      cached = params.cached or false,                                -- show staged changes if true
      mode = params.unified and "unified" or "vimdiff",               -- display mode
      path = params["current-file"] and vim.fn.expand("%:p") or nil,  -- filter to current file
    })
  elseif subcmd == "log" then
    -- Parse the -n count option for limiting number of commits
    local count = nil
    if params.n then
      count = tonumber(params.n)
      -- Validate that count is a positive number
      if not count or count <= 0 then
        vim.notify("Git log: -n requires a positive number", vim.log.levels.WARN)
        return
      end
    end
    -- Open the git log viewer with the specified filters
    require("plugins.git.log").open({
      path = params["current-file"] and vim.fn.expand("%:p") or nil,  -- filter to current file
      count = count,                                                   -- max commits to show
      author = params.author,                                          -- filter by author
    })
  elseif subcmd == "blame" then
    -- Toggle inline blame annotations for the current buffer
    require("plugins.git.blame").toggle({
      date = params.date,                          -- date format (relative, short, etc.)
      ignore_whitespace = params.w or false,       -- ignore whitespace changes in blame
    })
  end
end

--- Fetch recent commit hashes for tab-completion.
-- Runs `git log --oneline -n 30` and extracts the abbreviated commit hashes.
---@return string[] commits Array of abbreviated commit hash strings
local function get_commits()
  -- Execute git log synchronously to get recent commits
  local result = vim.system({ "git", "log", "--oneline", "-n", "30" }, { text = true }):wait()
  -- Return empty list if the command failed or produced no output
  if result.code ~= 0 or not result.stdout then
    return {}
  end
  -- Extract the first word (commit hash) from each output line
  local commits = {}
  for line in result.stdout:gmatch("[^\n]+") do
    commits[#commits + 1] = line:match("^(%S+)")
  end
  return commits
end

--- Provide tab-completion candidates for the :Git command.
-- Completes subcommands when typing the first argument, and completes
-- flags and commit refs when typing subsequent arguments.
---@param arglead string The current argument being typed (partial text)
---@param cmdline string The full command line text so far
---@return string[] candidates List of completion candidates matching arglead
function M.complete(arglead, cmdline)
  -- Split the command line into parts to determine completion context
  local parts = vim.split(cmdline, "%s+", { trimempty = true })
  -- Determine if we are completing the subcommand itself (first arg after "Git")
  local completing_subcmd = #parts == 1 or (#parts == 2 and arglead ~= "")
  if completing_subcmd then
    -- Complete against available subcommands
    local subcmds = { "status", "diff", "log", "blame" }
    return vim.tbl_filter(function(s)
      return s:find(arglead, 1, true) == 1
    end, subcmds)
  end
  -- Determine which subcommand is active to offer context-specific flags
  local subcmd = parts[2]
  local flags = {}
  if subcmd == "status" then
    -- Status supports --unified flag for unified diff display
    flags = { "--unified" }
  elseif subcmd == "diff" then
    -- Diff supports --cached, --unified, and --current-file flags
    flags = { "--cached", "--unified", "--current-file" }
  elseif subcmd == "log" then
    -- Log supports --current-file, --author=, and -n flags
    flags = { "--current-file", "--author=", "-n" }
  elseif subcmd == "blame" then
    -- Blame supports --date= variants and -w (ignore whitespace)
    flags = { "--date=relative", "--date=short", "-w" }
  end

  -- Start with flags as candidates
  local candidates = vim.list_extend({}, flags)
  -- For diff and log commands, also offer recent commit hashes as candidates
  if subcmd == "diff" or subcmd == "log" then
    vim.list_extend(candidates, get_commits())
  end

  -- Filter candidates to only those matching the current argument lead
  return vim.tbl_filter(function(s)
    return s:find(arglead, 1, true) == 1
  end, candidates)
end

return M
