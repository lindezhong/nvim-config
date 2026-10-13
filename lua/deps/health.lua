-- Health check for the system-level external dependencies this config relies on.
-- Run with :checkhealth deps
--
-- Two sections:
--   1. Per-tool probes — every missing tool is an ERROR with its own advice
--   2. "Unified install" — a separated section listing one full install
--      command per missing package, ready to copy-paste (continuation lines
--      get a 2-space indent from the health renderer; shells ignore it)
--
-- Package names are keyed by package manager in a single `alt` table
-- (apt default + per-PM overrides, including winget and brew keys):
--   Linux  apt / dnf / pacman / zypper / apk / xbps   (probed in this order;
--          the apt name is the fallback default)
--   macOS  brew (probed; without it the brew commands are still shown with
--          a "install Homebrew first" note)
--   Windows  winget — no detection, winget ships with Windows 10+
-- winget/brew only use explicit alt entries (no apt fallback), so tools that
-- ship with the OS there (tar, unzip) stay unmapped instead of producing a
-- broken command. Probes accept alternate executable names (python, gcc/
-- clang/cl) so a working tool is not reported missing.
--
-- Note: Mason covers editor tooling (LSP/DAP/linters) itself; this check only
-- covers what must exist on the system before nvim can do its job.

local M = {}

local IS_WIN = vim.fn.has("win32") == 1
local IS_MAC = vim.fn.has("mac") == 1

--- @class deps.Tool
--- @field exe string  primary executable name probed with executable()
--- @field also? string[]  extra acceptable executables (platform aliases)
--- @field apt string  package name on apt (Linux default)
--- @field purpose string  what breaks without it
--- @field alt? table<string,string>  per-PM package name overrides; valid
---          keys: dnf/pacman/zypper/apk/xbps (Linux) and winget/brew
--- @field mac_cmd? string  full install command for macOS when brew is not
---                          the right channel (e.g. Xcode Command Line Tools)

--- Tools probed for existence.
local TOOLS = {
  { exe = "git",     apt = "git",           purpose = "lazy.nvim plugin cloning",
    alt = { winget = "Git.Git", brew = "git" } },
  { exe = "curl",    apt = "curl",          purpose = "downloads (Mason, release tarballs)",
    alt = { winget = "cURL.cURL", brew = "curl" } },
  -- tar and unzip ship with Windows 10+ and macOS; no winget/brew entry,
  -- falls back to generic advice if genuinely missing.
  { exe = "tar",     apt = "tar",           purpose = "Mason archive extraction" },
  { exe = "unzip",   apt = "unzip",         purpose = "Mason .zip/.vsix extraction" },
  { exe = "rg",      apt = "ripgrep",       purpose = "telescope live_grep",
    alt = { winget = "BurntSushi.ripgrep.MSVC", brew = "ripgrep" } },
  -- Debian/Ubuntu and Alpine split npm out of nodejs; the other distros
  -- bundle it, so npm's alt maps back to nodejs there
  { exe = "node",    apt = "nodejs npm",    purpose = "npm-based LSP/DAP servers",
    alt = { dnf = "nodejs", pacman = "nodejs", zypper = "nodejs", xbps = "nodejs",
            winget = "OpenJS.NodeJS.LTS", brew = "node" } },
  { exe = "npm",     apt = "npm",           purpose = "npm-based LSP/DAP servers",
    alt = { dnf = "nodejs", pacman = "nodejs", zypper = "nodejs", xbps = "nodejs",
            winget = "OpenJS.NodeJS.LTS", brew = "node" } },
  { exe = "python3", also = { "python" }, apt = "python3", purpose = "debugpy venv",
    alt = { pacman = "python", winget = "Python.Python.3.12", brew = "python3" } },
  -- JDK 25 = current LTS; this config targets current distros only.
  -- jdtls' minimum runtime is 21 (enforced by the version check below)
  { exe = "java",    apt = "openjdk-25-jdk", purpose = "jdtls runtime",
    alt = { dnf = "java-25-openjdk-devel", pacman = "jdk25-openjdk",
            zypper = "java-25-openjdk-devel", apk = "openjdk25", xbps = "openjdk25",
            winget = "EclipseAdoptium.Temurin.25.JDK", brew = "openjdk@25" } },
  -- rust_analyzer itself is a prebuilt binary, but Cargo projects need cargo
  -- (rustup is the ecosystem-standard installer; distro cargo works too)
  { exe = "cargo",   apt = "cargo",          purpose = "rust_analyzer on Cargo projects",
    alt = { pacman = "rust", winget = "Rustlang.Rustup", brew = "rust" } },
  -- On macOS the compiler toolchain comes from Xcode CLT, not brew; on winget
  -- there is no plain C compiler (MSVC Build Tools install is interactive).
  -- Unmapped there. Aliases are gcc/clang/cl only: tree-sitter-cli invokes
  -- a C compiler, never zig on its own.
  { exe = "cc",      also = { "gcc", "clang", "cl" }, apt = "build-essential",
    purpose = "tree-sitter parser compilation",
    alt = { dnf = "gcc make", pacman = "base-devel", zypper = "gcc make",
            apk = "build-base", xbps = "base-devel" },
    mac_cmd = "xcode-select --install" },
}

--- Command prefix per package manager, e.g. "sudo apt-get install -y <pkg>".
--- xbps-install needs -S (sync) since it is not run as root with sudo here.
local INSTALL_PREFIX = {
  apt = "sudo apt-get install -y",
  dnf = "sudo dnf install -y",
  pacman = "sudo pacman -S --needed",
  zypper = "sudo zypper install",
  apk = "sudo apk add",
  xbps = "sudo xbps-install -S",
  winget = "winget install -e --id",
  brew = "brew install",
}

--- Package manager used for install advice.
---   Windows: always winget — it ships with Windows 10+, no detection needed.
---   macOS: brew if installed, else nil (brew commands are still suggested
---   alongside an "install Homebrew first" note).
---   Linux: first match among the probed managers, else nil.
--- A nil result on Linux degrades the report to generic advice.
--- @return string|nil
local function detect_pm()
  if IS_WIN then
    return "winget"
  end
  if IS_MAC then
    return vim.fn.executable("brew") == 1 and "brew" or nil
  end
  for _, pm in ipairs({ "apt-get", "dnf", "pacman", "zypper", "apk", "xbps-install" }) do
    if vim.fn.executable(pm) == 1 then
      if pm == "apt-get" then return "apt" end
      if pm == "xbps-install" then return "xbps" end
      return pm
    end
  end
  return nil
end

--- Package name(s) for a tool on a package manager, or nil when unmapped.
--- Linux PMs fall back to the apt name; winget/brew use explicit alt entries
--- only (the apt default must not leak into a different namespace).
--- @param tool deps.Tool
--- @param pm string|nil
--- @return string|nil
local function pkg_for(tool, pm)
  if pm == "winget" or pm == "brew" then
    return tool.alt and tool.alt[pm] or nil
  end
  return (tool.alt and pm and tool.alt[pm]) or tool.apt
end

--- Windows Store execution-alias stubs (in WindowsApps) appear on PATH even
--- when the tool is not installed; verify such candidates actually execute.
--- Runs the resolved absolute path, not the bare name, so the subprocess
--- cannot resolve to a different binary than exepath found.
--- @return boolean
local function is_runnable(path)
  if not IS_WIN or not path:lower():find("windowsapps", 1, true) then
    return true
  end
  local ok, res = pcall(function()
    return vim.system({ path, "--version" }, { timeout = 5000 }):wait()
  end)
  return ok and res ~= nil and res.code == 0
end

--- Resolve the executable actually present for a tool, trying aliases.
--- @param tool deps.Tool
--- @return string|nil name  matched executable name, nil when none found
--- @return string path  path of the match (valid when name is non-nil)
local function found(tool)
  local names = { tool.exe }
  vim.list_extend(names, tool.also or {})
  for _, name in ipairs(names) do
    local path = vim.fn.exepath(name)
    if path ~= "" and is_runnable(path) then
      return name, path
    end
  end
  return nil, ""
end

--- Parse the major version from `<java> -version` output, if parseable.
--- Handles modern ("21.0.5"), dotless ("21") and legacy ("1.8.0_422" = Java 8)
--- schemes without assuming a dot is present.
--- @param path string  resolved java executable path
--- @return integer|nil
local function java_major(path)
  local ok, res = pcall(function()
    return vim.system({ path, "-version" }, { text = true, timeout = 5000 }):wait()
  end)
  if not ok or not res then return nil end
  local out = (res.stderr or "") .. (res.stdout or "")
  local v = out:match('version "([%d]+[%d_.]*)')
  if not v then return nil end
  local first, second = v:match("^(%d+)%.(%d+)")
  if first == "1" then return tonumber(second) end -- legacy scheme: 1.8 = Java 8
  return tonumber(v:match("^(%d+)"))
end

function M.check()
  local pm = detect_pm()

  vim.health.start("deps: system dependencies")

  -- Neovim version floor (vim.lsp.enable and other 0.11+ APIs)
  if vim.version().major > 0 or vim.version().minor >= 11 then
    vim.health.ok(("Neovim %d.%d (%s)"):format(
      vim.version().major, vim.version().minor, vim.v.progpath))
  else
    vim.health.error(
      ("Neovim %d.%d is too old, need 0.11+"):format(vim.version().major, vim.version().minor),
      { "install an official build from https://github.com/neovim/neovim/releases" })
  end

  -- Section 1: per-tool probes.
  -- missing_cmds collects one full install command per missing package for
  -- the unified section at the end; unmapped collects tools without a
  -- package mapping on this platform (kept as per-item advice only).
  -- resolved executable paths reused by the java/venv detail checks below,
  -- so they spawn the exact binary exepath found (aliases included), never
  -- re-resolving a bare name through the child's PATH
  local missing_count = 0
  local missing_cmds, seen, unmapped = {}, {}, {}
  local java_path, python_path
  local function add_cmd(cmd)
    if not seen[cmd] then
      seen[cmd] = true
      missing_cmds[#missing_cmds + 1] = cmd
    end
  end
  local function add_pkgs(prefix, pkgs)
    for pkg in pkgs:gmatch("%S+") do
      add_cmd(("%s %s"):format(prefix, pkg))
    end
  end

  for _, tool in ipairs(TOOLS) do
    local name, path = found(tool)
    if name then
      if tool.exe == "java" then java_path = path end
      if tool.exe == "python3" then python_path = path end
      local label = name == tool.exe and tool.exe or ("%s (as %s)"):format(tool.exe, name)
      vim.health.ok(("%s found: %s"):format(label, path))
    else
      local advice
      if IS_MAC and tool.mac_cmd then
        -- macOS channel outside brew (e.g. Xcode CLT)
        advice = ("%s  # %s"):format(tool.mac_cmd, tool.purpose)
        add_cmd(tool.mac_cmd)
      else
        -- macOS without Homebrew still gets brew commands (with a note)
        local lookup_pm = pm or (IS_MAC and "brew" or nil)
        local pkgs = pkg_for(tool, lookup_pm)
        local prefix = lookup_pm and INSTALL_PREFIX[lookup_pm]
        if prefix and pkgs then
          advice = ("%s %s  # %s"):format(prefix, pkgs, tool.purpose)
          add_pkgs(prefix, pkgs)
        else
          advice = ("install %s for: %s"):format(tool.exe, tool.purpose)
          unmapped[#unmapped + 1] = tool.exe
        end
      end
      vim.health.error(("%s not found — %s"):format(tool.exe, tool.purpose), { advice })
      missing_count = missing_count + 1
    end
  end

  -- java version detail (jdtls needs 21+ to run, Eclipse platform 2024-09+)
  if java_path then
    local major = java_major(java_path)
    if not major then
      vim.health.warn("java found but version could not be determined (jdtls needs 21+)",
        { "check the output of `java -version`" })
    elseif major < 21 then
      vim.health.warn(("java %d found but jdtls needs 21+"):format(major),
        { "upgrade the JDK with your package manager" })
    else
      vim.health.ok(("java %d"):format(major))
    end
  end

  -- python venv support (debugpy builds its venv via Mason; vim-dashboard
  -- builds need it too). Probes ensurepip, not venv: on Debian/Ubuntu the
  -- venv module imports fine without the python3-venv package, but venv
  -- creation then fails (ensurepip is what the split package provides).
  -- Windows/macOS bundle ensurepip. Probes the resolved executable path
  -- with the same 5s cap as the java probe.
  if python_path then
    local ok, code = pcall(function()
      return vim.system({ python_path, "-c", "import ensurepip" }, { timeout = 5000 }):wait().code
    end)
    if ok and code == 0 then
      vim.health.ok("python venv support available (ensurepip)")
    else
      vim.health.warn("python present but ensurepip missing — venv creation fails (debugpy install will fail)",
        { pm == "apt" and "sudo apt-get install -y python3-venv" or "install the python venv package" })
      if pm == "apt" then
        missing_count = missing_count + 1
        add_pkgs(INSTALL_PREFIX.apt, "python3-venv")
      end
    end
  elseif pm == "apt" then
    -- python3 itself missing: the Debian/Ubuntu python3 package ships without
    -- ensurepip, so python3-venv is needed alongside it
    missing_count = missing_count + 1
    add_pkgs(INSTALL_PREFIX.apt, "python3-venv")
  end

  -- Section 2: unified install — one full command per missing package,
  -- clearly separated from the per-tool report above. Commands are passed as
  -- continuation lines of a single message (newline-joined): only the first
  -- line gets the health icon prefix, so every command is directly
  -- copy-pasteable (the renderer's 2-space indent is shell-inert).
  if missing_count > 0 then
    vim.health.start("deps: unified install")
    local header = ("%d dependencies missing"):format(missing_count)
    if #missing_cmds > 0 then
      header = header .. " — per-package commands:"
    end
    local parts = { header }
    if IS_MAC and not pm and #missing_cmds > 0 then
      parts[#parts + 1] = "# Homebrew not found — install it first: https://brew.sh"
    end
    vim.list_extend(parts, missing_cmds)
    if #unmapped > 0 then
      -- shell-comment style so a pasted block stays harmless
      parts[#parts + 1] = ("# no package mapping for %s on %s — see individual entries above")
        :format(table.concat(unmapped, ", "), pm or "this platform")
    end
    vim.health.warn(table.concat(parts, "\n"))
  end
end

return M
