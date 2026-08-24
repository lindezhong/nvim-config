-- Machine-local config reader.
-- Reads lua/local.lua (gitignored) and exposes its values with safe defaults.
local ok, cfg = pcall(require, "local")
if not ok then cfg = {} end

local M = {}

M.java_runtimes = cfg.java_runtimes or {}

return M
