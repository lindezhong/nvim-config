-- Machine-local config reader.
-- Reads lua/local.lua (gitignored) and merges into default structure.

---@class JavaRuntime
---@field name "JavaSE-1.8"|"JavaSE-9"|"JavaSE-10"|"JavaSE-11"|"JavaSE-12"|"JavaSE-13"|"JavaSE-14"|"JavaSE-15"|"JavaSE-16"|"JavaSE-17"|"JavaSE-18"|"JavaSE-19"|"JavaSE-20"|"JavaSE-21"|"JavaSE-22"|"JavaSE-23" Eclipse ExecutionEnvironment name, must match project's target Java version
---@field path string absolute path to JDK root directory, e.g. "/opt/jdk8"

---@class LocalConfig
---@field java_runtimes JavaRuntime[] Local JDK installations registered to jdtls so it can compile projects targeting different Java versions (used by plugins/nvim-jdtls.lua → settings.java.configuration.runtimes)

local ok, cfg = pcall(require, "local")
if not ok then cfg = {} end

---@type LocalConfig
return {
  java_runtimes = cfg.java_runtimes or {},
}
