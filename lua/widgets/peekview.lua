-- peekview.lua: generic code location browser with list + preview interface.
--
-- view.lua-style component: create() returns a view instance with on/emit
-- events, an open/close lifecycle, and self.buf pointing at the list buffer.
--
-- Two display modes:
--   "float" - centered floating windows (list on top + preview below)
--   "split" - bottom split window for list, source window shows preview
--
-- Events: "cursor" (selected item changed), "jump" (item activated),
-- "close" (view closed via any path).
--
-- Usage:
--   local pv = require("widgets.peekview").create({ ... })
--   pv:open()
--   -- or one-shot: require("widgets.peekview").open({ ... })

-- Single location entry data structure (extends GotoLocation with display fields)
---@class PeekViewItem : GotoLocation
---@field text? string text content of the line
---@field data? any caller-defined custom data, peekview does not use this

-- Window layout configuration
---@class PeekViewLayout
---@field preview_before? integer lines shown above the target line in preview
---@field preview_after? integer lines shown below the target line in preview
---@field min_width? integer minimum float window width in columns
---@field max_width_ratio? number maximum float window width as fraction of screen (0-1)
---@field max_height_ratio? number maximum list height as fraction of screen (0-1)
---@field split_height? integer list window height in split mode (rows)

-- Keybinding configuration
---@class PeekViewKeys
---@field jump? string key to jump to the selected location
---@field close? string key to close the peekview window

-- Highlight group configuration
---@class PeekViewHighlights
---@field float? string highlight group for float window background/border
---@field select? string highlight group for the currently selected line
---@field preview? string highlight group for the target keyword in preview

-- Full parameter table for peekview.create()
---@class PeekViewOpts
---@field items PeekViewItem[] location list
---@field title? string list window title (default "Results")
---@field preview_title? string preview window title (default "Preview")
---@field word? string keyword to highlight; if nil, highlights the entire line
---@field mode? "float"|"split" display mode (default "float")
---@field source_win? integer window to jump into (default: current window at call time)
---@field render? fun(item: PeekViewItem): string custom render function, returns one line of text
---@field layout? PeekViewLayout layout config, missing fields use defaults
---@field keys? PeekViewKeys keybinding config, missing fields use defaults
---@field highlights? PeekViewHighlights highlight group config, missing fields use defaults

local view = require("widgets.view")
local goto_loc = require("plugins.lsp.goto")
local buf_utils = require("plugins.lsp.buf")

local M = {}

-- Namespace for preview highlights, ensures no conflict with other plugins
---@type integer
local ns = vim.api.nvim_create_namespace("peekview")

-- Default layout values
---@type PeekViewLayout
local default_layout = {
  preview_before = 5,     -- 5 lines above target
  preview_after = 5,      -- 5 lines below target
  min_width = 50,         -- minimum 50 columns
  max_width_ratio = 0.8,  -- max 80% of screen width
  max_height_ratio = 0.3, -- list max 30% of screen height
  split_height = 10,      -- split mode 10 rows
}

-- Default keybindings
---@type PeekViewKeys
local default_keys = {
  jump = "<CR>",  -- Enter to jump
  close = "q",    -- q to close
}

-- Default highlight groups (must be defined in highlights.lua)
---@type PeekViewHighlights
local default_highlights = {
  float = "PeekViewFloat",      -- float window background
  select = "PeekViewSelect",    -- selected line
  preview = "PeekViewPreview",  -- preview keyword
}

-- Default render: formats item as "relative/path:lnum  text content"
---@param item PeekViewItem
---@return string
local function default_render(item)
  -- ":~" = relative to home (~/...), ":." = relative to cwd; combined prefers cwd-relative
  return vim.fn.fnamemodify(item.filename, ":~:.") .. ":" .. item.lnum .. "  " .. (item.text or "")
end

-- Clear all peekview highlights from the given buffer.
-- Called each time preview switches to avoid stale highlights.
---@param buf integer? buffer to clear, nil is a no-op
local function clear_highlight(buf)
  if buf and buf ~= -1 then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

-- Add keyword highlight in the preview buffer.
-- If word is provided, highlights exact range [col, col+len);
-- otherwise highlights the entire line (end_col = -1).
---@param buf integer target buffer
---@param item PeekViewItem location info (provides col)
---@param word string? keyword to highlight (optional)
---@param hl_group string highlight group name to use
local function add_highlight(buf, item, word, hl_group)
  local line_idx = item.lnum - 1
  if not word then
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx, 0, {
      end_row = line_idx, end_col = 0, hl_eol = true, hl_group = hl_group, priority = 200,
    })
    return
  end
  -- Try item.col first; if the word doesn't match there, search the line
  local lines = vim.api.nvim_buf_get_lines(buf, line_idx, line_idx + 1, false)
  if #lines == 0 then return end
  local line = lines[1]
  local start_col = item.col - 1
  if line:sub(start_col + 1, start_col + #word) ~= word then
    local found = line:find(word, 1, true)
    if found then
      start_col = found - 1
    else
      vim.api.nvim_buf_set_extmark(buf, ns, line_idx, 0, {
        end_row = line_idx, end_col = 0, hl_eol = true, hl_group = hl_group, priority = 200,
      })
      return
    end
  end
  vim.api.nvim_buf_set_extmark(buf, ns, line_idx, start_col, {
    end_col = start_col + #word, hl_group = hl_group, priority = 200,
  })
end

--- Create a new peekview instance.
---@param opts PeekViewOpts configuration parameters
---@return table pv the view instance with open/close/jump methods
function M.create(opts)
  -- Event emitter and lifecycle base
  local self = view.create()

  -- Merge user config with defaults ("keep" strategy: user values win, gaps filled by defaults)
  local layout = vim.tbl_extend("keep", opts.layout or {}, default_layout)
  local keys = vim.tbl_extend("keep", opts.keys or {}, default_keys)
  local highlights = vim.tbl_extend("keep", opts.highlights or {}, default_highlights)
  -- Render function: fall back to default "path:lnum  text" format
  local render = opts.render or default_render

  local items = opts.items or {}
  local mode = opts.mode == "split" and "split" or "float"
  -- Use caller-provided source window, or fall back to current window
  local source_win = opts.source_win or vim.api.nvim_get_current_win()
  local word = opts.word

  -- Convert all items to display strings via the render function (1:1 with items)
  local display_lines = {}
  for _, item in ipairs(items) do
    display_lines[#display_lines + 1] = render(item)
  end

  local list_win = nil       ---@type integer?
  local preview_win = nil    ---@type integer? float mode only
  local original_buf = nil   ---@type integer? source window state for split-mode restore
  local original_cursor = nil ---@type integer[]?
  local prev_buf = nil       ---@type integer? last previewed buffer (highlight cleanup)
  local augroup = nil        ---@type integer?
  local closed = false       ---@type boolean guard against double cleanup

  -- Update preview: load the file for the currently selected item, show it
  -- in target_win, position cursor, and highlight the keyword.
  ---@param target_win integer
  local function update_preview(target_win)
    if not vim.api.nvim_win_is_valid(list_win) then return end
    local cursor_row = vim.api.nvim_win_get_cursor(list_win)[1]
    local item = items[cursor_row]
    if not item or not vim.api.nvim_win_is_valid(target_win) then return end
    self:emit("cursor", item)
    -- Clear highlight from previous buffer
    clear_highlight(prev_buf)
    -- Load target file into buffer (gets syntax highlighting)
    local file_buf = buf_utils.ensure_loaded(item.filename)
    -- Switch preview window buffer (no flicker)
    vim.api.nvim_win_set_buf(target_win, file_buf)
    -- Position cursor at target line (clamp to buffer line count) and center
    local line_count = vim.api.nvim_buf_line_count(file_buf)
    local target_line = math.min(item.lnum, line_count)
    vim.api.nvim_win_set_cursor(target_win, { math.max(1, target_line), 0 })
    vim.api.nvim_win_call(target_win, function()
      vim.cmd("normal! zz")
    end)
    -- Highlight the target keyword in the preview window
    add_highlight(file_buf, item, word, highlights.preview)
    -- Remember this buffer for next cleanup
    prev_buf = file_buf
  end

  -- Cleanup: close windows, remove autocmds, clear highlights, optionally
  -- restore the source window (split mode). Idempotent via closed guard.
  ---@param restore_source boolean
  local function cleanup(restore_source)
    if closed then return end
    closed = true
    if augroup then pcall(vim.api.nvim_del_augroup_by_id, augroup) end
    clear_highlight(prev_buf)
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_close(preview_win, true)
    end
    if list_win and vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_win_close(list_win, true)
    end
    if restore_source and mode == "split" and vim.api.nvim_win_is_valid(source_win) then
      vim.api.nvim_win_set_buf(source_win, original_buf)
      vim.api.nvim_win_set_cursor(source_win, original_cursor)
    end
  end

  -- Close the view (any path: q key, <Esc>, jump, external :q).
  -- Emits "close"; buffer is wiped via bufhidden when the window closes.
  function self.close()
    if closed then return end
    self:emit("close")
    cleanup(true)
  end

  -- Jump to the selected location. Split mode skips restoring the source
  -- window (the jump target replaces it); emits "jump".
  function self.jump()
    if closed or not list_win or not vim.api.nvim_win_is_valid(list_win) then return end
    local item = items[vim.api.nvim_win_get_cursor(list_win)[1]]
    if not item then return end
    self:emit("jump", item)
    cleanup(mode ~= "split")
    goto_loc.jump_to(source_win, item)
  end

  -- Create the list buffer (unlisted, scratch, wiped on close)
  local function create_list_buf()
    local list_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, display_lines)
    vim.bo[list_buf].modifiable = false
    vim.bo[list_buf].buftype = "nofile"
    vim.bo[list_buf].bufhidden = "wipe"
    vim.bo[list_buf].filetype = "peekview"
    return list_buf
  end

  -- Watch cursor movement in the list to update the preview in real time,
  -- and close the view when a window is closed externally (:q, :close).
  local function setup_autocmds()
    augroup = vim.api.nvim_create_augroup("peekview_preview", { clear = true })
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = augroup,
      buffer = self.buf,
      callback = function()
        if mode == "float" then
          update_preview(preview_win)
        else
          update_preview(source_win)
        end
      end,
    })
    local patterns = { tostring(list_win) }
    if preview_win then patterns[#patterns + 1] = tostring(preview_win) end
    vim.api.nvim_create_autocmd("WinClosed", {
      group = augroup,
      pattern = patterns,
      once = true,
      callback = function() self.close() end,
    })
  end

  -- Bind jump/close keys to the list buffer (nowait avoids timeout waiting for key combos)
  local function setup_keymaps()
    local map_opts = { buffer = self.buf, nowait = true, silent = true }
    vim.keymap.set("n", keys.jump, function() self.jump() end, map_opts)
    vim.keymap.set("n", keys.close, function() self.close() end, map_opts)
    vim.keymap.set("n", "<Esc>", function() self.close() end, map_opts)
  end

  -- Float mode: centered floating windows (list on top + preview below)
  local function open_float()
    -- Calculate float width: max display width of all lines, clamped to [min, max]
    local max_width = 0
    for _, line in ipairs(display_lines) do
      -- strdisplaywidth handles multi-byte characters correctly
      max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
    end
    -- +2 for 1 column padding on each side
    local width = math.min(
      math.max(max_width + 2, layout.min_width),
      math.floor(vim.o.columns * layout.max_width_ratio)
    )
    -- List height: smaller of item count and max allowed height
    local list_height = math.min(#items, math.floor(vim.o.lines * layout.max_height_ratio))
    -- Preview height: context lines above + target line + context lines below
    local preview_height = layout.preview_before + layout.preview_after + 1
    -- Total height: each window has +2 for border (top+bottom)
    local total_height = (list_height + 2) + (preview_height + 2)
    -- Center position on screen (width+2 accounts for left+right border)
    local start_row = math.floor((vim.o.lines - total_height) / 2)
    local start_col = math.floor((vim.o.columns - (width + 2)) / 2)

    self.buf = create_list_buf()

    -- Open list float window (focused)
    list_win = vim.api.nvim_open_win(self.buf, true, {
      relative = "editor",  -- positioned relative to the full editor
      width = width,
      height = list_height,
      row = start_row,
      col = start_col,
      style = "minimal",
      border = (vim.o.winborder ~= "" and vim.o.winborder ~= "none") and vim.o.winborder or "rounded",
      title = " " .. (opts.title or "Results") .. " ",
      title_pos = "center",
    })
    vim.wo[list_win].number = vim.go.number
    -- Show cursor line highlight bar
    vim.wo[list_win].cursorline = true
    -- Override window highlight groups: background uses float, cursor line uses select
    vim.wo[list_win].winhighlight = "NormalFloat:" .. highlights.float .. ",FloatBorder:" .. highlights.float .. ",CursorLine:" .. highlights.select .. ",CursorLineNr:LineNr"

    -- Open preview float window (unfocused, initially shows list_buf as placeholder)
    preview_win = vim.api.nvim_open_win(self.buf, false, {
      relative = "editor",
      width = width,
      height = preview_height,
      row = start_row + list_height + 2,  -- below list window (content + top/bottom border)
      col = start_col,
      style = "minimal",
      border = (vim.o.winborder ~= "" and vim.o.winborder ~= "none") and vim.o.winborder or "rounded",
      title = " " .. (opts.preview_title or "Preview") .. " ",
      title_pos = "center",
    })
    vim.wo[preview_win].number = vim.go.number
    -- Preview window background color
    vim.wo[preview_win].winhighlight = "NormalFloat:" .. highlights.float .. ",FloatBorder:" .. highlights.float

    setup_keymaps()
    setup_autocmds()
    -- Show first item's preview immediately on open
    update_preview(preview_win)
  end

  -- Split mode: bottom split for list, source window shows preview
  local function open_split()
    -- Save source window original state for restore on close
    original_buf = vim.api.nvim_win_get_buf(source_win)
    original_cursor = vim.api.nvim_win_get_cursor(source_win)

    -- Create horizontal split at the bottom
    vim.cmd("botright " .. layout.split_height .. "split")
    -- The newly created split becomes the current window
    list_win = vim.api.nvim_get_current_win()

    self.buf = create_list_buf()
    vim.api.nvim_win_set_buf(list_win, self.buf)
    -- List window style: show cursor line, hide line numbers and sign column
    vim.wo[list_win].cursorline = true
    vim.wo[list_win].number = false
    vim.wo[list_win].relativenumber = false
    vim.wo[list_win].signcolumn = "no"
    -- Hide statusline (otherwise shows "[Scratch] [-]" from buftype/modifiable)
    vim.wo[list_win].statusline = " "
    -- Only override CursorLine highlight (split mode doesn't need background override)
    vim.wo[list_win].winhighlight = "CursorLine:" .. highlights.select

    setup_keymaps()
    setup_autocmds()
    -- Show first item's preview in the source window immediately on open
    update_preview(source_win)
  end

  --- Open the peekview (selects float or split mode based on opts.mode).
  function self.open()
    if closed then return end
    if #items == 0 then return end
    if mode == "split" then
      open_split()
    else
      open_float()
    end
  end

  return self
end

--- One-shot helper: create and open in a single call.
---@param opts PeekViewOpts configuration parameters
---@return table pv the view instance (already open)
function M.open(opts)
  local pv = M.create(opts)
  pv:open()
  return pv
end

return M
