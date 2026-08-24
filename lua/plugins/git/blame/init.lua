-- blame/init.lua
-- Git blame panel that displays per-line commit attribution alongside the source buffer.
--
-- Architecture:
--   Creates a fixed-width vertical split (left of source) containing a scratch buffer
--   with formatted blame info (hash, author, date) for each line. The blame panel and
--   source window are synchronized via scrollbind + manual cursor sync (CursorMoved).
--
-- Features:
--   - Always blames from current buffer contents (--contents -), supporting unsaved edits
--   - Handles CRLF/CR line endings and non-UTF-8 encodings (latin1, gbk, etc.)
--   - Per-commit hash coloring using xterm-256 color palette
--   - Debounced auto-rebuild when source line count changes (150ms)
--   - Press <CR> on any line to open the full commit diff (defaults to current file)
--   - Press q to close the blame panel
--   - Uses `aboveleft vsplit` to avoid stealing space from nvim-tree or other sidebars
--
-- Public API:
--   M.show(opts)    -- Open blame panel for the current buffer
--   M.toggle(opts)  -- Toggle blame panel open/close
--   M.close()       -- Close blame panel and restore source window options
--
-- State:
--   Module-level singleton `state` -- only one blame panel can be open at a time.
--   Contains: blame_win, blame_buf, source_win, source_buf, blame_data, path, opts,
--   saved_opts (original scrollbind/foldenable), rebuild_timer.

local git = require("plugins.git.git")
local diff_window = require("plugins.git.diff.diffwindow")

local api = vim.api

--- @type table Module table exported by this file
local M = {}

---@class BlameState
---@field blame_win integer Window ID of the blame panel
---@field blame_buf integer Buffer ID of the blame panel
---@field source_win integer Window ID of the original source file
---@field source_buf integer Buffer ID of the original source file
---@field blame_data BlameEntry[] Parsed blame entries (one per source line)
---@field saved_opts {scrollbind: boolean, foldenable: boolean} Original source window options to restore on close
---@field path string Git-relative path of the blamed file
---@field opts BlameOpts User options passed to M.show()
---@field rebuild_timer uv_timer_t|nil Debounce timer for auto-rebuild on edits

---@class BlameEntry
---@field hash string Full 40-char commit hash (all zeros for uncommitted)
---@field author string Author name
---@field date string|nil Formatted date string

---@class BlameOpts
---@field ignore_whitespace boolean|nil Ignore whitespace changes in blame
---@field date string|nil Date format passed to git blame

--- @type BlameState|nil Module-level singleton state; only one blame panel at a time
local state = nil

--- @type integer Namespace ID for extmark highlights in the blame buffer
local ns = api.nvim_create_namespace("git_blame")

--- Xterm-256 color palette mapping index (0-255) to hex color strings.
--- Used to assign a unique foreground color to each commit hash.
---@type table<integer, string>
local color_table = {
  [0]='#000000',    [1]='#800000',    [2]='#008000',    [3]='#808000',
  [4]='#000080',    [5]='#800080',    [6]='#008080',    [7]='#c0c0c0',
  [8]='#808080',    [9]='#ff0000',    [10]='#00ff00',   [11]='#ffff00',
  [12]='#0000ff',   [13]='#ff00ff',   [14]='#00ffff',   [15]='#ffffff',
  [16]='#000000',   [17]='#00005f',   [18]='#000087',   [19]='#0000af',
  [20]='#0000d7',   [21]='#0000ff',   [22]='#005f00',   [23]='#005f5f',
  [24]='#005f87',   [25]='#005faf',   [26]='#005fd7',   [27]='#005fff',
  [28]='#008700',   [29]='#00875f',   [30]='#008787',   [31]='#0087af',
  [32]='#0087d7',   [33]='#0087ff',   [34]='#00af00',   [35]='#00af5f',
  [36]='#00af87',   [37]='#00afaf',   [38]='#00afd7',   [39]='#00afff',
  [40]='#00d700',   [41]='#00d75f',   [42]='#00d787',   [43]='#00d7af',
  [44]='#00d7d7',   [45]='#00d7ff',   [46]='#00ff00',   [47]='#00ff5f',
  [48]='#00ff87',   [49]='#00ffaf',   [50]='#00ffd7',   [51]='#00ffff',
  [52]='#5f0000',   [53]='#5f005f',   [54]='#5f0087',   [55]='#5f00af',
  [56]='#5f00d7',   [57]='#5f00ff',   [58]='#5f5f00',   [59]='#5f5f5f',
  [60]='#5f5f87',   [61]='#5f5faf',   [62]='#5f5fd7',   [63]='#5f5fff',
  [64]='#5f8700',   [65]='#5f875f',   [66]='#5f8787',   [67]='#5f87af',
  [68]='#5f87d7',   [69]='#5f87ff',   [70]='#5faf00',   [71]='#5faf5f',
  [72]='#5faf87',   [73]='#5fafaf',   [74]='#5fafd7',   [75]='#5fafff',
  [76]='#5fd700',   [77]='#5fd75f',   [78]='#5fd787',   [79]='#5fd7af',
  [80]='#5fd7d7',   [81]='#5fd7ff',   [82]='#5fff00',   [83]='#5fff5f',
  [84]='#5fff87',   [85]='#5fffaf',   [86]='#5fffd7',   [87]='#5fffff',
  [88]='#870000',   [89]='#87005f',   [90]='#870087',   [91]='#8700af',
  [92]='#8700d7',   [93]='#8700ff',   [94]='#875f00',   [95]='#875f5f',
  [96]='#875f87',   [97]='#875faf',   [98]='#875fd7',   [99]='#875fff',
  [100]='#878700',  [101]='#87875f',  [102]='#878787',  [103]='#8787af',
  [104]='#8787d7',  [105]='#8787ff',  [106]='#87af00',  [107]='#87af5f',
  [108]='#87af87',  [109]='#87afaf',  [110]='#87afd7',  [111]='#87afff',
  [112]='#87d700',  [113]='#87d75f',  [114]='#87d787',  [115]='#87d7af',
  [116]='#87d7d7',  [117]='#87d7ff',  [118]='#87ff00',  [119]='#87ff5f',
  [120]='#87ff87',  [121]='#87ffaf',  [122]='#87ffd7',  [123]='#87ffff',
  [124]='#af0000',  [125]='#af005f',  [126]='#af0087',  [127]='#af00af',
  [128]='#af00d7',  [129]='#af00ff',  [130]='#af5f00',  [131]='#af5f5f',
  [132]='#af5f87',  [133]='#af5faf',  [134]='#af5fd7',  [135]='#af5fff',
  [136]='#af8700',  [137]='#af875f',  [138]='#af8787',  [139]='#af87af',
  [140]='#af87d7',  [141]='#af87ff',  [142]='#afaf00',  [143]='#afaf5f',
  [144]='#afaf87',  [145]='#afafaf',  [146]='#afafd7',  [147]='#afafff',
  [148]='#afd700',  [149]='#afd75f',  [150]='#afd787',  [151]='#afd7af',
  [152]='#afd7d7',  [153]='#afd7ff',  [154]='#afff00',  [155]='#afff5f',
  [156]='#afff87',  [157]='#afffaf',  [158]='#afffd7',  [159]='#afffff',
  [160]='#d70000',  [161]='#d7005f',  [162]='#d70087',  [163]='#d700af',
  [164]='#d700d7',  [165]='#d700ff',  [166]='#d75f00',  [167]='#d75f5f',
  [168]='#d75f87',  [169]='#d75faf',  [170]='#d75fd7',  [171]='#d75fff',
  [172]='#d78700',  [173]='#d7875f',  [174]='#d78787',  [175]='#d787af',
  [176]='#d787d7',  [177]='#d787ff',  [178]='#d7af00',  [179]='#d7af5f',
  [180]='#d7af87',  [181]='#d7afaf',  [182]='#d7afd7',  [183]='#d7afff',
  [184]='#d7d700',  [185]='#d7d75f',  [186]='#d7d787',  [187]='#d7d7af',
  [188]='#d7d7d7',  [189]='#d7d7ff',  [190]='#d7ff00',  [191]='#d7ff5f',
  [192]='#d7ff87',  [193]='#d7ffaf',  [194]='#d7ffd7',  [195]='#d7ffff',
  [196]='#ff0000',  [197]='#ff005f',  [198]='#ff0087',  [199]='#ff00af',
  [200]='#ff00d7',  [201]='#ff00ff',  [202]='#ff5f00',  [203]='#ff5f5f',
  [204]='#ff5f87',  [205]='#ff5faf',  [206]='#ff5fd7',  [207]='#ff5fff',
  [208]='#ff8700',  [209]='#ff875f',  [210]='#ff8787',  [211]='#ff87af',
  [212]='#ff87d7',  [213]='#ff87ff',  [214]='#ffaf00',  [215]='#ffaf5f',
  [216]='#ffaf87',  [217]='#ffafaf',  [218]='#ffafd7',  [219]='#ffafff',
  [220]='#ffd700',  [221]='#ffd75f',  [222]='#ffd787',  [223]='#ffd7af',
  [224]='#ffd7d7',  [225]='#ffd7ff',  [226]='#ffff00',  [227]='#ffff5f',
  [228]='#ffff87',  [229]='#ffffaf',  [230]='#ffffd7',  [231]='#ffffff',
  [232]='#080808',  [233]='#121212',  [234]='#1c1c1c',  [235]='#262626',
  [236]='#303030',  [237]='#3a3a3a',  [238]='#444444',  [239]='#4e4e4e',
  [240]='#585858',  [241]='#626262',  [242]='#6c6c6c',  [243]='#767676',
  [244]='#808080',  [245]='#8a8a8a',  [246]='#949494',  [247]='#9e9e9e',
  [248]='#a8a8a8',  [249]='#b2b2b2',  [250]='#bcbcbc',  [251]='#c6c6c6',
  [252]='#d0d0d0',  [253]='#dadada',  [254]='#e4e4e4',  [255]='#eeeeee',
}

--- Get or create a highlight group for a commit hash.
--- Maps the first byte of the hash to a xterm-256 color index, creating the
--- highlight group on first use. This gives each commit a visually distinct color.
---@param hash string Full commit hash (at least 2 hex chars)
---@return string hl_name The highlight group name (e.g. "Lf_hl_blame_42")
local function get_hash_hl(hash)
  local n = tonumber(hash:sub(1, 2), 16) or 0
  local hl_name = "Lf_hl_blame_" .. n
  if vim.fn.hlexists(hl_name) == 0 then
    api.nvim_set_hl(0, hl_name, { ctermfg = n, fg = color_table[n] })
  end
  return hl_name
end

--- Restore the source window's original options (scrollbind, foldenable) and
--- remove the <CR> keymap that was temporarily set on the source buffer.
---@param s BlameState|nil The state to restore from; no-op if nil
local function restore_source_opts(s)
  if s and api.nvim_win_is_valid(s.source_win) then
    vim.wo[s.source_win].scrollbind = s.saved_opts.scrollbind
    vim.wo[s.source_win].foldenable = s.saved_opts.foldenable
  end
  if s and api.nvim_buf_is_valid(s.source_buf) then
    pcall(vim.keymap.del, "n", "<CR>", { buffer = s.source_buf })
  end
end

--- Close the blame panel, stop the rebuild timer, and restore source window options.
function M.close()
  if not state then
    return
  end
  local s = state
  state = nil

  if s.rebuild_timer then
    s.rebuild_timer:stop()
    s.rebuild_timer:close()
  end
  if api.nvim_win_is_valid(s.blame_win) then
    api.nvim_win_close(s.blame_win, true)
  end
  restore_source_opts(s)
end

--- Toggle the blame panel: close if open, open if closed.
---@param opts BlameOpts|nil Options forwarded to M.show()
function M.toggle(opts)
  if state and api.nvim_win_is_valid(state.blame_win) then
    M.close()
  else
    M.show(opts)
  end
end

--- Open the blame panel for the current buffer.
--- Retrieves blame data via `git blame --contents -`, formats it into a left-side
--- panel, sets up scrollbind/cursor sync, and registers keymaps and autocmds.
---@param opts BlameOpts|nil Options: ignore_whitespace, date format
function M.show(opts)
  opts = opts or {}
  if state then
    M.close()
  end

  local source_win = api.nvim_get_current_win()
  local source_buf = api.nvim_win_get_buf(source_win)
  local abs_path = api.nvim_buf_get_name(source_buf)
  if abs_path == "" then
    vim.notify("No file to blame", vim.log.levels.WARN)
    return
  end
  -- Resolve path relative to git root for reliable blame
  local root = git.root()
  if not root then
    vim.notify("Not in a git repository", vim.log.levels.WARN)
    return
  end
  local path
  if abs_path:sub(1, #root + 1) == root .. "/" then
    path = abs_path:sub(#root + 2)
  else
    path = vim.fn.fnamemodify(abs_path, ":.")
  end

  -- Always blame from buffer contents so the view stays in sync with
  -- what the user sees, regardless of unsaved modifications.
  -- Reconstruct the byte stream matching the on-disk format (EOL + encoding).
  local buf_lines = api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local ff = vim.bo[source_buf].fileformat
  local eol = ff == "dos" and "\r\n" or ff == "mac" and "\r" or "\n"
  local contents = table.concat(buf_lines, eol)
  if vim.bo[source_buf].endofline then
    contents = contents .. eol
  end
  local fenc = vim.bo[source_buf].fileencoding
  if fenc ~= "" and fenc ~= "utf-8" then
    contents = vim.iconv(contents, "utf-8", fenc)
  end
  local blame_data = git.blame({
    path = path,
    ignore_whitespace = opts.ignore_whitespace,
    date = opts.date,
    contents = contents,
  })
  if #blame_data == 0 then
    vim.notify("No blame data (file may not be tracked by git)", vim.log.levels.WARN)
    return
  end

  -- Format blame lines and compute width
  local max_author = 0
  for _, bl in ipairs(blame_data) do
    if not bl.hash:match("^0+$") then
      max_author = math.max(max_author, #bl.author)
    end
  end
  max_author = math.min(max_author, 16)

  local formatted = {}
  local segments = {}
  for _, bl in ipairs(blame_data) do
    local hash = bl.hash:sub(1, 7)
    local author = bl.author:sub(1, max_author)
    author = author .. string.rep(" ", max_author - #author)
    local date = bl.date or ""
    if hash:match("^0+$") then
      formatted[#formatted + 1] = ""
      segments[#segments + 1] = { uncommitted = true }
    else
      local line = hash .. " " .. author .. " " .. date
      formatted[#formatted + 1] = line
      local author_start = 8
      local author_end = 8 + #author
      local date_start = author_end + 1
      local date_end = #line
      segments[#segments + 1] = {
        hash_end = 7,
        author_start = author_start,
        author_end = author_end,
        date_start = date_start,
        date_end = date_end,
      }
    end
  end

  local panel_width = 0
  for _, line in ipairs(formatted) do
    if #line > panel_width then
      panel_width = #line
    end
  end
  panel_width = panel_width + 1

  -- Save source window options
  local saved_opts = {
    scrollbind = vim.wo[source_win].scrollbind,
    foldenable = vim.wo[source_win].foldenable,
  }

  -- Open blame panel to the left of the source window.
  -- Use `aboveleft vsplit` (same as LeaderF) which splits relative to the
  -- current window without stealing space from other fixed-width sidebars.
  local cursor_line = api.nvim_win_get_cursor(source_win)[1]
  local blame_buf = api.nvim_create_buf(false, true)
  api.nvim_set_current_win(source_win)
  vim.cmd("noautocmd aboveleft " .. panel_width .. "vsplit")
  local blame_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(blame_win, blame_buf)

  -- Fill buffer
  api.nvim_buf_set_lines(blame_buf, 0, -1, false, formatted)
  api.nvim_buf_set_name(blame_buf, "git://blame:" .. path)
  vim.bo[blame_buf].buftype = "nofile"
  vim.bo[blame_buf].bufhidden = "wipe"
  vim.bo[blame_buf].swapfile = false
  vim.bo[blame_buf].modifiable = false
  vim.bo[blame_buf].filetype = "git_blame"

  -- Highlight group for date
  if vim.fn.hlexists("GitBlameDate") == 0 then
    api.nvim_set_hl(0, "GitBlameDate", { link = "Number" })
  end

  -- Highlight: hash (per-commit color), date (Number), author stays default
  for i, bl in ipairs(blame_data) do
    local seg = segments[i]
    local row = i - 1
    if seg.uncommitted then
      if #formatted[i] > 0 then
        api.nvim_buf_set_extmark(blame_buf, ns, row, 0, {
          end_col = #formatted[i],
          hl_group = "Comment",
        })
      end
    else
      api.nvim_buf_set_extmark(blame_buf, ns, row, 0, {
        end_col = seg.hash_end,
        hl_group = get_hash_hl(bl.hash),
      })
      api.nvim_buf_set_extmark(blame_buf, ns, row, seg.date_start, {
        end_col = seg.date_end,
        hl_group = "GitBlameDate",
      })
    end
  end

  -- Blame window options (no cursorline - user doesn't want underline)
  vim.wo[blame_win].wrap = false
  vim.wo[blame_win].winfixwidth = true
  vim.wo[blame_win].foldcolumn = "0"
  vim.wo[blame_win].foldenable = false
  vim.wo[blame_win].number = false
  vim.wo[blame_win].relativenumber = false
  vim.wo[blame_win].signcolumn = "no"
  vim.wo[blame_win].cursorline = false
  vim.wo[blame_win].scrolloff = 0

  -- Sync cursor position with source
  local top_line = vim.fn.line("w0", source_win)
  vim.cmd("norm! " .. top_line .. "Gzt" .. cursor_line .. "G0")

  -- Enable scrollbind only (no cursorbind - it interferes with line sync)
  vim.wo[blame_win].scrollbind = true
  vim.wo[source_win].foldenable = false
  vim.wo[source_win].scrollbind = true
  vim.cmd("syncbind")

  state = {
    blame_win = blame_win,
    blame_buf = blame_buf,
    source_win = source_win,
    source_buf = source_buf,
    blame_data = blame_data,
    saved_opts = saved_opts,
    path = path,
    opts = opts,
  }

  -- Keymaps on blame buffer
  vim.keymap.set("n", "q", M.close, { buffer = blame_buf, silent = true })
  vim.keymap.set("n", "<CR>", M._open_commit, { buffer = blame_buf, silent = true })

  -- Enter on source buffer opens commit diff (active while blame is open)
  vim.keymap.set("n", "<CR>", M._open_commit, { buffer = source_buf, silent = true })

  -- Rebuild blame view when line count changes (debounced)
  local rebuild_timer = vim.uv.new_timer()
  state.rebuild_timer = rebuild_timer
  api.nvim_buf_attach(source_buf, false, {
    on_lines = function(_, _, _, first, old_last, new_last)
      if not state or state.blame_buf ~= blame_buf then
        return true
      end
      if new_last == old_last then
        return
      end
      rebuild_timer:stop()
      rebuild_timer:start(150, 0, vim.schedule_wrap(function()
        if not state or state.blame_buf ~= blame_buf then
          return
        end
        if not api.nvim_buf_is_valid(blame_buf) then
          return
        end
        M._rebuild_view()
      end))
    end,
  })

  local augroup = api.nvim_create_augroup("git_blame_" .. blame_buf, { clear = true })

  -- Sync blame cursor to source cursor (replaces cursorbind)
  api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = source_buf,
    callback = function()
      if not state or state.blame_buf ~= blame_buf then
        return true
      end
      if not api.nvim_win_is_valid(blame_win) then
        return true
      end
      local src_line = api.nvim_win_get_cursor(source_win)[1]
      local blame_count = api.nvim_buf_line_count(blame_buf)
      if src_line <= blame_count then
        api.nvim_win_set_cursor(blame_win, { src_line, 0 })
      end
    end,
  })

  -- Auto-close when blame buffer is wiped externally
  api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = blame_buf,
    once = true,
    callback = function()
      if state and state.blame_buf == blame_buf then
        local s = state
        state = nil
        if s.rebuild_timer then
          s.rebuild_timer:stop()
          s.rebuild_timer:close()
        end
        restore_source_opts(s)
      end
    end,
  })

  -- Auto-close when blame window gets taken over by another buffer (e.g. NvimTree)
  api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function(ev)
      if not state or state.blame_buf ~= blame_buf then
        return true
      end
      local win = api.nvim_get_current_win()
      if win == state.blame_win and ev.buf ~= blame_buf then
        vim.schedule(M.close)
        return true
      end
    end,
  })

  -- Focus stays in source window
  vim.cmd("noautocmd call win_gotoid(" .. source_win .. ")")
end

--- Open the diff window for the commit under the cursor.
--- Determines the current line from either the blame or source window,
--- retrieves the commit's file list, and opens the diff view defaulting
--- to the currently blamed file.
function M._open_commit()
  if not state then
    return
  end
  local cur_win = api.nvim_get_current_win()
  local line
  if cur_win == state.blame_win then
    line = api.nvim_win_get_cursor(state.blame_win)[1]
  else
    line = api.nvim_win_get_cursor(state.source_win)[1]
  end
  local bl = state.blame_data[line]
  if not bl then
    return
  end
  local hash = bl.hash
  if hash:match("^0+$") then
    vim.notify("Not committed yet", vim.log.levels.INFO)
    return
  end

  local files = git.commit_files(hash) or {}
  if #files == 0 then
    vim.notify("No files in commit " .. hash:sub(1, 7), vim.log.levels.WARN)
    return
  end

  local current_path = state.path
  M.close()
  diff_window.open({
    files = files,
    ref1 = hash .. "^",
    ref2 = hash,
    mode = "vimdiff",
    current_file = current_path,
  })
end

--- Rebuild the blame panel contents after the source buffer's line count changes.
--- Re-runs git blame with current buffer contents, reformats the blame lines,
--- re-applies highlights, and restores scrollbind synchronization.
function M._rebuild_view()
  if not state then
    return
  end
  local s = state
  if not api.nvim_win_is_valid(s.blame_win) or not api.nvim_win_is_valid(s.source_win) then
    return
  end

  -- Temporarily disable scrollbind to prevent drift during buffer update
  vim.wo[s.blame_win].scrollbind = false
  vim.wo[s.source_win].scrollbind = false

  local buf_lines = api.nvim_buf_get_lines(s.source_buf, 0, -1, false)
  local ff = vim.bo[s.source_buf].fileformat
  local eol = ff == "dos" and "\r\n" or ff == "mac" and "\r" or "\n"
  local contents = table.concat(buf_lines, eol)
  if vim.bo[s.source_buf].endofline then
    contents = contents .. eol
  end
  local fenc = vim.bo[s.source_buf].fileencoding
  if fenc ~= "" and fenc ~= "utf-8" then
    contents = vim.iconv(contents, "utf-8", fenc)
  end
  local blame_data = git.blame({
    path = s.path,
    ignore_whitespace = s.opts and s.opts.ignore_whitespace,
    date = s.opts and s.opts.date,
    contents = contents,
  })
  if #blame_data == 0 then
    vim.wo[s.blame_win].scrollbind = true
    vim.wo[s.source_win].scrollbind = true
    return
  end
  s.blame_data = blame_data

  local max_author = 0
  for _, bl in ipairs(blame_data) do
    if not bl.hash:match("^0+$") then
      max_author = math.max(max_author, #bl.author)
    end
  end
  max_author = math.min(max_author, 16)

  local formatted = {}
  for _, bl in ipairs(blame_data) do
    if bl.hash:match("^0+$") then
      formatted[#formatted + 1] = ""
    else
      local hash = bl.hash:sub(1, 7)
      local author = bl.author:sub(1, max_author)
      author = author .. string.rep(" ", max_author - #author)
      formatted[#formatted + 1] = hash .. " " .. author .. " " .. (bl.date or "")
    end
  end

  vim.bo[s.blame_buf].modifiable = true
  api.nvim_buf_set_lines(s.blame_buf, 0, -1, false, formatted)
  vim.bo[s.blame_buf].modifiable = false

  -- Re-apply highlights
  api.nvim_buf_clear_namespace(s.blame_buf, ns, 0, -1)
  for i, bl in ipairs(blame_data) do
    local line = formatted[i]
    if not bl.hash:match("^0+$") and line ~= "" then
      api.nvim_buf_set_extmark(s.blame_buf, ns, i - 1, 0, {
        end_col = 7,
        hl_group = get_hash_hl(bl.hash),
      })
      local date_start = line:find("%d%d%d%d%-%d%d%-%d%d") or line:find("%d+ %a+ ago") or line:find("just now")
      if date_start then
        api.nvim_buf_set_extmark(s.blame_buf, ns, i - 1, date_start - 1, {
          end_col = #line,
          hl_group = "GitBlameDate",
        })
      end
    end
  end

  -- Restore scrollbind and sync position
  local src_line = api.nvim_win_get_cursor(s.source_win)[1]
  local blame_count = api.nvim_buf_line_count(s.blame_buf)
  if src_line <= blame_count then
    api.nvim_win_set_cursor(s.blame_win, { src_line, 0 })
  end
  vim.wo[s.blame_win].scrollbind = true
  vim.wo[s.source_win].scrollbind = true
  vim.cmd("syncbind")
end

return M
