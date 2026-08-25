-- PeekView: generic code location browser with list + preview interface.
--
-- Supports two display modes:
--   "float" - centered floating windows (list on top + preview below)
--   "split" - bottom split window for list, source window shows preview
--
-- The caller provides items (code location list), peekview handles all UI:
-- window creation, list rendering, preview loading, keyword highlighting,
-- jumping, and closing.
--
-- Usage:
--   require("plugins.lsp.peekview").open({
--     items = { {filename, lnum, col, text, data}, ... },
--     title = "References (5)",
--     preview_title = "Preview",
--     word = "symbol",
--     mode = "float",
--     source_win = vim.api.nvim_get_current_win(),
--     render = function(item) end,
--     layout = { ... },
--     keys = { jump, close },
--     highlights = { float, select, preview },
--   })

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

-- Full parameter table for peekview.open()
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

-- Internal resolved options (all fields guaranteed non-nil after merging defaults)
---@class PeekViewResolvedOpts
---@field title string list window title
---@field preview_title? string preview window title
---@field word? string keyword to highlight
---@field layout PeekViewLayout layout config (defaults merged)
---@field keys PeekViewKeys keybinding config (defaults merged)
---@field highlights PeekViewHighlights highlight config (defaults merged)

--------------------------------------------------------------------------
-- Float mode: centered floating windows (list on top + preview below)
--------------------------------------------------------------------------

---@param items PeekViewItem[] location list
---@param display_lines string[] rendered display text (1:1 with items)
---@param opts PeekViewResolvedOpts resolved configuration
---@param source_win integer source window to jump into
local function open_float(items, display_lines, opts, source_win)
  local layout = opts.layout
  local keys = opts.keys
  local hl = opts.highlights

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

  -- Create list buffer (unlisted, scratch, wiped on close)
  local list_buf = vim.api.nvim_create_buf(false, true)
  -- Fill with rendered text lines
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, display_lines)
  -- Prevent accidental editing
  vim.bo[list_buf].modifiable = false
  -- Not associated with any file on disk
  vim.bo[list_buf].buftype = "nofile"
  -- Completely remove buffer when window closes
  vim.bo[list_buf].bufhidden = "wipe"
  -- Custom filetype for autocmd/highlight matching
  vim.bo[list_buf].filetype = "peekview"

  -- Open list float window (focused)
  local list_win = vim.api.nvim_open_win(list_buf, true, {
    relative = "editor",  -- positioned relative to the full editor
    width = width,
    height = list_height,
    row = start_row,
    col = start_col,
    -- Use global winborder if set, otherwise default to rounded (required for title)
    border = (vim.o.winborder ~= "" and vim.o.winborder ~= "none") and vim.o.winborder or "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "center",
  })
  vim.wo[list_win].number = vim.go.number
  vim.wo[list_win].signcolumn = "no"
  vim.wo[list_win].foldcolumn = "0"
  vim.wo[list_win].spell = false
  -- Show cursor line highlight bar
  vim.wo[list_win].cursorline = true
  -- Override window highlight groups: background uses float, cursor line uses select
  vim.wo[list_win].winhighlight = "NormalFloat:" .. hl.float .. ",FloatBorder:" .. hl.float .. ",CursorLine:" .. hl.select .. ",CursorLineNr:LineNr"

  -- Open preview float window (unfocused, initially shows list_buf as placeholder)
  local preview_win = vim.api.nvim_open_win(list_buf, false, {
    relative = "editor",
    width = width,
    height = preview_height,
    row = start_row + list_height + 2,  -- below list window (content + top/bottom border)
    col = start_col,
    -- Use global winborder if set, otherwise default to rounded (required for title)
    border = (vim.o.winborder ~= "" and vim.o.winborder ~= "none") and vim.o.winborder or "rounded",
    title = " " .. (opts.preview_title or "Preview") .. " ",
    title_pos = "center",
  })
  vim.wo[preview_win].number = vim.go.number
  vim.wo[preview_win].signcolumn = "no"
  vim.wo[preview_win].foldcolumn = "0"
  vim.wo[preview_win].spell = false
  -- Preview window background color
  vim.wo[preview_win].winhighlight = "NormalFloat:" .. hl.float .. ",FloatBorder:" .. hl.float

  -- Track previously previewed buffer to clear its highlight on switch
  ---@type integer?
  local prev_buf = nil

  -- Update preview: load the file for the currently selected item and highlight keyword
  local function update_preview()
    -- Preview window may have been closed by user via :q or :close
    if not vim.api.nvim_win_is_valid(preview_win) then return end
    -- Cursor row in list corresponds to items index
    local cursor_row = vim.api.nvim_win_get_cursor(list_win)[1]
    local item = items[cursor_row]
    if not item then return end

    -- Clear highlight from previous buffer
    clear_highlight(prev_buf)
    -- Load target file into buffer (gets syntax highlighting)
    local file_buf = buf_utils.ensure_loaded(item.filename)
    -- Switch preview window buffer (no flicker)
    vim.api.nvim_win_set_buf(preview_win, file_buf)
    -- Position cursor at target line (clamp to buffer line count)
    local line_count = vim.api.nvim_buf_line_count(file_buf)
    local target_line = math.min(item.lnum, line_count)
    vim.api.nvim_win_set_cursor(preview_win, { math.max(1, target_line), 0 })
    -- Center the target line vertically in preview
    vim.api.nvim_win_call(preview_win, function()
      vim.cmd("normal! zz")
    end)
    -- Highlight the target keyword in the preview window
    add_highlight(file_buf, item, opts.word, hl.preview)
    -- Remember this buffer for next cleanup
    prev_buf = file_buf
  end

  -- Show first item's preview immediately on open
  update_preview()

  -- Watch cursor movement in list to update preview in real-time
  local augroup = vim.api.nvim_create_augroup("peekview_preview", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = list_buf,
    callback = update_preview,
  })

  -- Guard flag: prevents double-cleanup when close/jump triggers WinClosed
  local closed = false

  -- Cleanup: close both windows, remove autocmds, clear highlights.
  -- Idempotent: safe to call multiple times due to closed guard.
  local function cleanup()
    if closed then return end
    closed = true
    vim.api.nvim_del_augroup_by_id(augroup)
    clear_highlight(prev_buf)
    if vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_close(preview_win, true)
    end
    if vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_win_close(list_win, true)
    end
  end

  -- Jump action: close all float windows, then jump to selected location
  local function do_jump()
    local cursor_row = vim.api.nvim_win_get_cursor(list_win)[1]
    local item = items[cursor_row]
    if not item then return end
    cleanup()
    goto_loc.jump_to(source_win, item)
  end

  -- Bind keys to list buffer (nowait avoids timeout waiting for key combos)
  local map_opts = { buffer = list_buf, nowait = true }
  vim.keymap.set("n", keys.jump, do_jump, map_opts)
  vim.keymap.set("n", keys.close, cleanup, map_opts)
  vim.keymap.set("n", "<Esc>", cleanup, map_opts)

  -- Linked cleanup: if either window is closed externally (:q, :close),
  -- close the other window and run cleanup to avoid orphaned windows.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = { tostring(list_win), tostring(preview_win) },
    once = true,
    callback = cleanup,
  })
end

--------------------------------------------------------------------------
-- Split mode: bottom split for list, source window shows preview
--------------------------------------------------------------------------

---@param items PeekViewItem[] location list
---@param display_lines string[] rendered display text
---@param opts PeekViewResolvedOpts resolved configuration
---@param source_win integer source window (used for preview and jump target)
local function open_split(items, display_lines, opts, source_win)
  local layout = opts.layout
  local keys = opts.keys
  local hl = opts.highlights
  -- Save source window original state for restore on close
  local original_buf = vim.api.nvim_win_get_buf(source_win)
  local original_cursor = vim.api.nvim_win_get_cursor(source_win)

  -- Create horizontal split at the bottom
  vim.cmd("botright " .. layout.split_height .. "split")
  -- The newly created split becomes the current window
  local list_win = vim.api.nvim_get_current_win()
  -- Create and populate list buffer
  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(list_win, list_buf)
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, display_lines)
  -- List buffer properties
  vim.bo[list_buf].modifiable = false
  vim.bo[list_buf].buftype = "nofile"
  vim.bo[list_buf].bufhidden = "wipe"
  vim.bo[list_buf].filetype = "peekview"
  -- List window style: show cursor line, hide line numbers and sign column
  vim.wo[list_win].cursorline = true
  vim.wo[list_win].number = false
  vim.wo[list_win].relativenumber = false
  vim.wo[list_win].signcolumn = "no"
  -- Hide statusline (otherwise shows "[Scratch] [-]" from buftype/modifiable)
  vim.wo[list_win].statusline = " "
  -- Only override CursorLine highlight (split mode doesn't need background override)
  vim.wo[list_win].winhighlight = "CursorLine:" .. hl.select

  -- Track previously previewed buffer
  ---@type integer?
  local prev_buf = nil

  -- Update preview: show the selected item's file in the source window
  local function update_preview()
    local cursor_row = vim.api.nvim_win_get_cursor(list_win)[1]
    local item = items[cursor_row]
    -- Source window may have been closed by user
    if not item or not vim.api.nvim_win_is_valid(source_win) then return end

    -- Clear previous file's highlight
    clear_highlight(prev_buf)
    -- Load target file
    local file_buf = buf_utils.ensure_loaded(item.filename)
    -- Show file in source window (replaces current buffer)
    vim.api.nvim_win_set_buf(source_win, file_buf)
    vim.api.nvim_win_set_cursor(source_win, { item.lnum, 0 })
    -- Center target line vertically
    vim.api.nvim_win_call(source_win, function()
      vim.cmd("normal! zz")
    end)
    -- Highlight target keyword
    add_highlight(file_buf, item, opts.word, hl.preview)
    prev_buf = file_buf
  end

  -- Show first item's preview on open
  update_preview()

  -- Watch cursor movement to update source window preview
  local augroup = vim.api.nvim_create_augroup("peekview_preview", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = list_buf,
    callback = update_preview,
  })

  -- Guard flag: prevents double-cleanup when close/jump triggers WinClosed
  local closed = false

  -- Close and restore: close list window, remove autocmds, restore source window.
  -- Idempotent: safe to call multiple times due to closed guard.
  local function close()
    if closed then return end
    closed = true
    vim.api.nvim_del_augroup_by_id(augroup)
    clear_highlight(prev_buf)
    if vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_win_close(list_win, true)
    end
    -- Restore source window to its original file and cursor position
    if vim.api.nvim_win_is_valid(source_win) then
      vim.api.nvim_win_set_buf(source_win, original_buf)
      vim.api.nvim_win_set_cursor(source_win, original_cursor)
    end
  end

  -- Jump: close list window, jump to selected location (no restore)
  local function do_jump()
    local cursor_row = vim.api.nvim_win_get_cursor(list_win)[1]
    local item = items[cursor_row]
    if not item then return end
    if closed then return end
    closed = true
    vim.api.nvim_del_augroup_by_id(augroup)
    clear_highlight(prev_buf)
    if vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_win_close(list_win, true)
    end
    goto_loc.jump_to(source_win, item)
  end

  -- Bind keys
  local map_opts = { buffer = list_buf, nowait = true }
  vim.keymap.set("n", keys.jump, do_jump, map_opts)
  vim.keymap.set("n", keys.close, close, map_opts)
  vim.keymap.set("n", "<Esc>", close, map_opts)

  -- Linked cleanup: if list window is closed externally (:q, :close),
  -- restore source window to original state.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(list_win),
    once = true,
    callback = close,
  })
end

--------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------

-- Open the PeekView location browser.
-- Selects float or split mode based on opts.mode and renders the location list
-- with real-time preview.
---@param opts PeekViewOpts configuration parameters
function M.open(opts)
  local items = opts.items
  -- Nothing to show
  if not items or #items == 0 then return end

  -- Merge user config with defaults ("keep" strategy: user values win, gaps filled by defaults)
  local layout = vim.tbl_extend("keep", opts.layout or {}, default_layout)
  local keys = vim.tbl_extend("keep", opts.keys or {}, default_keys)
  local highlights = vim.tbl_extend("keep", opts.highlights or {}, default_highlights)
  -- Render function: fall back to default "path:lnum  text" format
  local render = opts.render or default_render

  -- Build internal resolved config (all fields guaranteed non-nil)
  ---@type PeekViewResolvedOpts
  local resolved_opts = {
    title = opts.title or "Results",
    preview_title = opts.preview_title,
    word = opts.word,
    layout = layout,
    keys = keys,
    highlights = highlights,
  }

  -- Convert all items to display strings via the render function
  local display_lines = {}
  for _, item in ipairs(items) do
    table.insert(display_lines, render(item))
  end

  -- Use caller-provided source window, or fall back to current window
  local source_win = opts.source_win or vim.api.nvim_get_current_win()

  -- Dispatch to the appropriate UI mode
  if opts.mode == "split" then
    open_split(items, display_lines, resolved_opts, source_win)
  else
    open_float(items, display_lines, resolved_opts, source_win)
  end
end

return M
