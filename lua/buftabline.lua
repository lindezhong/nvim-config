-- Buffer tabline (custom implementation)
--
-- Displays all open buffers as tabs at the top of the screen.
-- Each tab shows the filename; the active buffer is highlighted differently
-- from background buffers. A configurable indicator marks unsaved changes.
--
-- Features:
-- 1. Current buffer: black text on light gray background (BufTabLineCurrent)
-- 2. Hidden buffers: bold + underline, no background (BufTabLineHidden)
-- 3. Modified indicator: "*" appended to filename for unsaved buffers
-- 4. Layout-stable: a space is always reserved for the indicator position
-- 5. Always visible: tabline shown regardless of buffer count (showtabline=2)
-- 6. Terminal integration: hide tabline when entering fullscreen :Terminal
-- 7. Overflow: center-on-current with space donation (vim-buftabline algorithm).
--    The tabline always fills the entire width. When tabs overflow, whole tabs
--    are removed from the outer edges, then the boundary tab is character-
--    truncated to fill the exact remaining space. «N / N» indicators (rendered
--    in fill highlight) show how many tabs are hidden on each side.
--
-- Tab format: " name*" or " name " (1-space left pad + name + indicator/space)
-- Separator between tabs: 1 space (fill-colored, or hidden-colored for underline continuity)

--- Indicator character appended to filename for modified (unsaved) buffers.
--- A space is always reserved at this position to prevent layout shift.
local modified_indicator = "*"

--- Highlight group names used for tabline elements
local hl = {
  -- Active/focused buffer tab
  current = "BufTabLineCurrent",
  -- Inactive/background buffer tabs
  hidden = "BufTabLineHidden",
  -- Empty area after all tabs and separator between tabs
  fill = "BufTabLineFill",
}

--- @type number Buffer number to center on. Persists across renders to prevent
--- jumps when a transient non-user buffer (e.g. help) gains focus.
local centerbuf = vim.api.nvim_get_current_buf()

--- @type number Display width of «/» (may be 2 in CJK terminals with ambiwidth=double)
local indicator_char_w = vim.api.nvim_strwidth("\u{ab}")

--- Compute the display width of an overflow indicator string.
--- Left: "«N " where N = hidden count. Right: " N»".
--- @param count number Number of hidden tabs
--- @return number Display columns consumed by the indicator
local function indicator_width(count)
  return indicator_char_w + #tostring(count) + 1
end

--- Skip at least `cols` display columns from the left of `str`.
--- If a wide character straddles the boundary, it is fully skipped (never under-skip).
--- @param str string Input string
--- @param cols number Minimum display columns to skip
--- @return string Remaining portion after skipping
local function skip_display_cols(str, cols)
  local skipped = 0
  local pos = 1
  while skipped < cols and pos <= #str do
    local ch = vim.fn.matchstr(str:sub(pos), ".")
    skipped = skipped + vim.api.nvim_strwidth(ch)
    pos = pos + #ch
  end
  return str:sub(pos)
end

--- Keep at most `cols` display columns from the left of `str`.
--- If a wide character would exceed the budget, it is excluded (never over-keep).
--- @param str string Input string
--- @param cols number Maximum display columns to keep
--- @return string Prefix within the given display width
local function keep_display_cols(str, cols)
  local kept = 0
  local pos = 1
  while pos <= #str do
    local ch = vim.fn.matchstr(str:sub(pos), ".")
    local ch_w = vim.api.nvim_strwidth(ch)
    if kept + ch_w > cols then break end
    kept = kept + ch_w
    pos = pos + #ch
  end
  return str:sub(1, pos - 1)
end

--- Build the tabline string from all listed buffers.
--- Uses vim-buftabline algorithm: center on current buffer, split screen into
--- halves, donate surplus from underflowing side, trim whole tabs from outer
--- edges then character-truncate the boundary tab, render with highlight codes.
--- @return string Vim tabline format string with %#HlGroup# highlight switches
local function render()
  local columns = vim.o.columns
  local current = vim.api.nvim_get_current_buf()

  -- Collect listed buffers
  --- @type {buf: number, name: string}[]
  local tabs = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.fn.buflisted(buf) == 1 then
      local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
      if name == "" then name = "[No Name]" end
      table.insert(tabs, { buf = buf, name = name })
    end
  end

  if #tabs == 0 then
    return "%#" .. hl.fill .. "#"
  end

  -- Resolve center buffer index (sticky across renders)
  --- @type number?
  local center_idx = nil
  for i, tab in ipairs(tabs) do
    if tab.buf == current then
      center_idx = i
      centerbuf = current
      break
    end
  end
  if not center_idx then
    for i, tab in ipairs(tabs) do
      if tab.buf == centerbuf then
        center_idx = i
        break
      end
    end
  end
  if not center_idx then
    center_idx = 1
    centerbuf = tabs[1].buf
  end

  -- Build raw labels and compute display widths.
  -- Format: "{sep} {name}{trailing}" where sep=" " for non-first tabs.
  -- Labels stored raw (no % escaping); escape deferred to render.
  --- @type string[]
  local labels = {}
  --- @type number[]
  local label_widths = {}

  for i, tab in ipairs(tabs) do
    local trailing = vim.bo[tab.buf].modified and modified_indicator or " "
    local content = " " .. tab.name .. trailing
    local sep = (i > 1) and " " or ""
    labels[i] = sep .. content
    label_widths[i] = vim.api.nvim_strwidth(labels[i])
  end

  -- Sum widths per side (center tab split between halves)
  local center_half = math.floor(label_widths[center_idx] / 2)
  local left_width = center_half
  local right_width = label_widths[center_idx] - center_half
  for i = 1, center_idx - 1 do left_width = left_width + label_widths[i] end
  for i = center_idx + 1, #tabs do right_width = right_width + label_widths[i] end

  -- Space donation and trimming
  local left_half = math.floor(columns / 2)
  local right_half = columns - left_half

  local first = 1
  local last = #tabs
  local left_overflow = false
  local right_overflow = false

  if (left_width + right_width) > columns then
    -- Budget with space donation
    local left_budget, right_budget
    if left_width < left_half then
      left_budget = left_width
      right_budget = columns - left_width
    elseif right_width < right_half then
      left_budget = columns - right_width
      right_budget = right_width
    else
      left_budget = left_half
      right_budget = right_half
    end

    -- Trim left side
    local left_delta = left_width - left_budget
    if left_delta > 0 then
      while first < center_idx and left_delta >= label_widths[first] do
        left_delta = left_delta - label_widths[first]
        first = first + 1
      end
      if first > 1 then
        left_overflow = true
        local ind_w = indicator_width(first - 1)
        local skip = left_delta + ind_w
        while skip >= label_widths[first] and first < center_idx do
          skip = skip - label_widths[first]
          first = first + 1
          local new_ind_w = indicator_width(first - 1)
          skip = skip + (new_ind_w - ind_w)
          ind_w = new_ind_w
        end
        if skip > 0 and skip < label_widths[first] then
          labels[first] = skip_display_cols(labels[first], skip)
          label_widths[first] = vim.api.nvim_strwidth(labels[first])
        elseif skip >= label_widths[first] then
          labels[first] = ""
          label_widths[first] = 0
        end
      else
        if left_delta > 0 and left_delta < label_widths[first] then
          labels[first] = skip_display_cols(labels[first], left_delta)
          label_widths[first] = vim.api.nvim_strwidth(labels[first])
        end
      end
    end

    -- Trim right side
    local right_delta = right_width - right_budget
    if right_delta > 0 then
      while last > center_idx and right_delta >= label_widths[last] do
        right_delta = right_delta - label_widths[last]
        last = last - 1
      end
      if last < #tabs then
        right_overflow = true
        local ind_w = indicator_width(#tabs - last)
        local trim = right_delta + ind_w
        while trim >= label_widths[last] and last > center_idx do
          trim = trim - label_widths[last]
          last = last - 1
          local new_ind_w = indicator_width(#tabs - last)
          trim = trim + (new_ind_w - ind_w)
          ind_w = new_ind_w
        end
        local keep = label_widths[last] - trim
        if keep > 0 and keep < label_widths[last] then
          labels[last] = keep_display_cols(labels[last], keep)
          label_widths[last] = vim.api.nvim_strwidth(labels[last])
        elseif keep <= 0 then
          labels[last] = ""
          label_widths[last] = 0
        end
      else
        if right_delta > 0 and right_delta < label_widths[last] then
          labels[last] = keep_display_cols(labels[last], label_widths[last] - right_delta)
          label_widths[last] = vim.api.nvim_strwidth(labels[last])
        end
      end
    end
  end

  -- Assemble tabline string with highlights
  local parts = {}

  if left_overflow then
    table.insert(parts, "%#" .. hl.fill .. "#\u{ab}" .. tostring(first - 1) .. " ")
  end

  local prev_group = nil
  for i = first, last do
    local tab = tabs[i]
    local group = (tab.buf == current) and hl.current or hl.hidden
    local label = labels[i]
    if label ~= "" then
      local escaped = label:gsub("%%", "%%%%")
      if i > first and escaped:sub(1, 1) == " " then
        -- Separator: use hidden highlight when both sides are hidden (underline continuity)
        local sep_hl = (prev_group == hl.hidden and group == hl.hidden) and hl.hidden or hl.fill
        table.insert(parts, "%#" .. sep_hl .. "# %#" .. group .. "#" .. escaped:sub(2))
      else
        table.insert(parts, "%#" .. group .. "#" .. escaped)
      end
      prev_group = group
    end
  end

  if right_overflow then
    table.insert(parts, "%#" .. hl.fill .. "# " .. tostring(#tabs - last) .. "\u{bb}")
  end

  return table.concat(parts) .. "%#" .. hl.fill .. "#"
end

--- Define highlight groups for the tabline using cterm attributes.
--- No termguicolors needed — works with any 16-color terminal palette.
local function setup_highlights()
  -- Current buffer: black text (ctermfg=0) on light gray background (ctermbg=7)
  vim.api.nvim_set_hl(0, hl.current, { ctermfg = 0, ctermbg = 7 })
  -- Hidden buffers: bold + underline text, transparent background (blends with terminal)
  vim.api.nvim_set_hl(0, hl.hidden, { cterm = { bold = true, underline = true } })
  -- Fill area: black background (ctermbg=0) to match typical dark terminal backgrounds
  vim.api.nvim_set_hl(0, hl.fill, { ctermbg = 0 })
end

--- Show the tabline.
local function enable()
  vim.o.showtabline = 2
  vim.o.tabline = "%!v:lua.require'buftabline'.render()"
end

--- Hide the tabline.
local function disable()
  vim.o.showtabline = 0
end

--- Toggle tabline visibility.
local function toggle()
  if vim.o.showtabline == 0 then enable() else disable() end
end

-- Initialize on first require
setup_highlights()
enable()

-- Re-apply highlights after colorscheme change
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = setup_highlights,
})

-- Force tabline redraw when buffer list or current buffer changes
vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufEnter" }, {
  callback = function() vim.schedule(function() vim.cmd.redrawtabline() end) end,
})

return {
  render = render,
  enable = enable,
  disable = disable,
  toggle = toggle,
}
