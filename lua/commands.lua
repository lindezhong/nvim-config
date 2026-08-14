-- Custom commands
--
-- :Exit     - quit without saving session (delete session file first)
-- :Q n      - quit n times (close multiple windows)
-- :Terminal  - open a clean fullscreen terminal

local M = {}

-- Hooks for :Terminal, plugins register their cleanup logic
M.terminal_hooks = {}

-- Register a plugin's terminal cleanup callback
-- Usage: require("commands").register_terminal("buftabline", function() ... end)
function M.register_terminal(name, fn)
  table.insert(M.terminal_hooks, { name = name, fn = fn })
end

-- Close unnamed, unmodified, normal buffers
local function close_unnamed_buffers()
  local current = vim.api.nvim_get_current_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.fn.buflisted(buf) == 1 and buf ~= current then
      local name = vim.api.nvim_buf_get_name(buf)
      local buftype = vim.bo[buf].buftype
      local modified = vim.bo[buf].modified
      if name == "" and not modified and buftype == "" then
        vim.cmd("silent bdelete " .. buf)
      end
    end
  end
end

-- :Exit - quit without triggering session save
vim.api.nvim_create_user_command("Exit", function()
  require("session").clear()
  vim.cmd("quit")
end, {})

-- :Q n - quit n times
vim.api.nvim_create_user_command("Q", function(opts)
  local n = tonumber(opts.args)
  if not n or n < 1 then
    vim.notify("Usage: :Q <number>", vim.log.levels.ERROR)
    return
  end
  for _ = 1, n do
    vim.cmd("quit")
  end
end, { nargs = 1 })

-- :Terminal - open a clean fullscreen terminal
vim.api.nvim_create_user_command("Terminal", function()
  -- Disable session save for this window
  require("session").clear()
  -- Call plugin cleanup hooks
  for _, hook in ipairs(M.terminal_hooks) do
    pcall(hook.fn)
  end
  vim.cmd("terminal")
  close_unnamed_buffers()
  vim.opt.showmode = false
  -- nvim exits terminal mode with <C-\><C-n>
  vim.keymap.set("t", "<Esc>", "<C-\\><C-n>")
  vim.opt.cmdheight = 0
  vim.cmd("redraw")
end, {})

return M
