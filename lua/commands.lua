-- Custom commands
--
-- :Exit - quit without saving session (delete session file first)
-- :Q n  - quit n times (close multiple windows)

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
