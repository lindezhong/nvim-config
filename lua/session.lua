-- Directory-level session management
--
-- Automatically save/load vim sessions per working directory.
-- Only activates when nvim opens a directory (not a single file).
-- Session files stored in stdpath("data")/sessions/ with path-encoded filenames.

local M = {}

-- Keep filetype info but remove blank windows and global options
vim.opt.sessionoptions:remove("blank")
vim.opt.sessionoptions:append("localoptions")
vim.opt.sessionoptions:remove("options")

local session_dir = vim.fn.stdpath("data") .. "/sessions"
local session_file = nil

-- Directories excluded from session management
local exclude_dirs = {}

-- Plugin hooks: other modules can register save/load callbacks
M.hooks = {
  on_save = {},
  on_load = {},
}

-- Register a plugin's session persistence callbacks
-- Usage: require("session").register("dap", { on_save = fn, on_load = fn })
-- Callback receives the session file path as argument
function M.register(name, opts)
  if opts.on_save then
    table.insert(M.hooks.on_save, { name = name, fn = opts.on_save })
  end
  if opts.on_load then
    table.insert(M.hooks.on_load, { name = name, fn = opts.on_load })
  end
end

-- Convert directory path to session filename (replace / with _)
local function path_to_filename(dir)
  return dir:gsub("/", "_") .. ".nvim"
end

-- Check if current directory is in the exclude list
local function is_excluded(dir)
  for _, excluded in ipairs(exclude_dirs) do
    if dir == excluded then
      return true
    end
  end
  return false
end

-- Initialize session file path based on current directory
local function init()
  local filepath = vim.fn.expand("%:p")
  local dirpath = vim.fn.expand("%:p:h")

  -- Only manage sessions when nvim opens a directory (not a file)
  if filepath ~= "" or is_excluded(dirpath) then
    return
  end

  if vim.fn.isdirectory(session_dir) == 0 then
    vim.fn.mkdir(session_dir, "p")
  end

  session_file = session_dir .. "/" .. path_to_filename(dirpath)
  M.load()
end

-- Save current session and call plugin hooks
function M.save()
  if not session_file or session_file == "" then
    return
  end
  vim.cmd("silent! mksession! " .. vim.fn.fnameescape(session_file))
  for _, hook in ipairs(M.hooks.on_save) do
    pcall(hook.fn, session_file)
  end
end

-- Load session if exists and call plugin hooks
function M.load()
  if not session_file or vim.fn.filereadable(session_file) == 0 then
    return
  end
  vim.cmd("silent! source " .. vim.fn.fnameescape(session_file))
  for _, hook in ipairs(M.hooks.on_load) do
    pcall(hook.fn, session_file)
  end
end

-- Delete session file (used by :Exit to quit without saving)
function M.clear()
  if session_file and vim.fn.filereadable(session_file) == 1 then
    vim.fn.delete(session_file)
  end
  -- Also clear plugin hook files
  for _, hook in ipairs(M.hooks.on_save) do
    local hook_file = session_file and (session_file .. "." .. hook.name)
    if hook_file and vim.fn.filereadable(hook_file) == 1 then
      vim.fn.delete(hook_file)
    end
  end
  session_file = nil
end

-- Return current session file path (for use by commands.lua)
function M.get_session_file()
  return session_file
end

-- Autocmds for automatic session management
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    init()
  end,
})

vim.api.nvim_create_autocmd("VimLeave", {
  callback = function()
    -- Wipe unlisted buffers before saving so mksession skips them
    -- (plugin drawers, results, help, etc. that aren't in buftabline)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.fn.buflisted(buf) == 0 then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    M.save()
  end,
})

-- Manual commands
vim.api.nvim_create_user_command("SaveSession", function()
  M.save()
end, {})

vim.api.nvim_create_user_command("LoadSession", function()
  M.load()
end, {})

return M
