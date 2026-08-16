-- :Terminal - open a clean fullscreen terminal
--
-- Enters terminal mode with a clean environment:
-- runs registered hooks, clears session, removes empty buffers.

local M = {}

--- @type function[] Cleanup hooks called before entering terminal mode
local hooks = {}

--- Register a cleanup hook for :Terminal.
--- @param fn function Called (via pcall) before entering terminal mode
function M.register(fn)
  table.insert(hooks, fn)
end

-- Close unnamed, unmodified, normal buffers
local function close_unnamed_buffers()
  local current = vim.api.nvim_get_current_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.fn.buflisted(buf) == 1 and buf ~= current then
      local name = vim.api.nvim_buf_get_name(buf)
      if name == "" and not vim.bo[buf].modified and vim.bo[buf].buftype == "" then
        vim.cmd("silent bdelete " .. buf)
      end
    end
  end
end

-- Register known hooks
M.register(function() require("buftabline").disable() end)
M.register(function() require("nvim-tree.api").tree.close() end)

vim.api.nvim_create_user_command("Terminal", function()
  require("session").clear()
  for _, fn in ipairs(hooks) do
    pcall(fn)
  end
  vim.cmd("terminal")
  close_unnamed_buffers()
  vim.opt.showmode = false
  vim.keymap.set("t", "<Esc>", "<C-\\><C-n>")
  vim.opt.cmdheight = 0
  vim.cmd("redraw")
end, {})

return M
