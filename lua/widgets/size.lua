-- size.lua: widget size spec resolution (absolute number or percentage string).

local M = {}

local api = vim.api

--- Whole-editor size along the axis.
---@param axis "width"|"height" axis to measure
---@return number vim.o.columns or vim.o.lines
local function editor_total(axis)
  return axis == "width" and vim.o.columns or vim.o.lines
end

--- Size of win's nearest parallel container along the axis ("width" → row,
--- "height" → col): branches are summed along the axis, and the widest /
--- tallest branch counts on the cross axis.
---@param win integer window whose container is measured
---@param axis "width"|"height" axis to measure
---@return number? nil when win has no matching container (fullscreen)
local function container_total(win, axis)
  local want = axis == "width" and "row" or "col"
  local layout = vim.fn.winlayout(api.nvim_win_get_tabpage(win))
  local size_fn = axis == "width" and api.nvim_win_get_width or api.nvim_win_get_height

  -- Walk towards win; remember the innermost matching ancestor container
  local found = nil
  local function find(node)
    if found then return false end
    if node[1] == "leaf" then
      return node[2] == win
    end
    for _, child in ipairs(node[2]) do
      if find(child) then
        if node[1] == want and not found then
          found = node
        end
        return true
      end
    end
    return false
  end
  find(layout)
  if not found then
    return nil  -- win found but has no matching container (fullscreen)
  end

  local function node_size(node)
    if node[1] == "leaf" then
      local w = node[2]
      return api.nvim_win_is_valid(w) and size_fn(w) or 0
    end
    -- row: children split the axis width -> sum; the other axis -> widest/tallest child
    local parallel = (node[1] == "row") == (axis == "width")
    local total = parallel and 0 or -1
    for _, child in ipairs(node[2]) do
      local s = node_size(child)
      if parallel then
        total = total + s
      else
        total = math.max(total, s)
      end
    end
    return math.max(0, total)
  end
  return node_size(found)
end

--- Resolve a size spec along an axis; unparsable values pass through.
--- Percentage base: win = its nearest parallel container (width → row /
--- height → col); nil = whole editor.
---@param value number|string number = absolute columns/rows; "N%" = percentage of the base
---@param axis "width"|"height" axis to resolve along (editor base: columns / lines)
---@param win integer? nil = percentage of whole editor; a window = percentage of its container
---@return number resolved size in columns/rows
function M.resolve(value, axis, win)
  if type(value) ~= "string" then
    return value
  end
  -- strip "%" (gsub returns count too, so capture only the string)
  local stripped = value:gsub("%%", "")
  local pct = tonumber(stripped)
  if not pct then
    return value
  end
  local total = editor_total(axis)
  if win and api.nvim_win_is_valid(win) then
    total = container_total(win, axis) or total
  end
  return math.max(1, math.floor(total * pct / 100))
end

return M
