-- document_outline.lua: LSP document symbol outline (tree panel).
--
-- Shows all symbols of the current buffer (markdown: headings via marksman)
-- in a hierarchical tree panel. Selecting a node jumps to the symbol.
--
-- Architecture follows call_hierarchy.lua:
--   - UI: treeview.lua
--   - LSP: single textDocument/documentSymbol request, whole tree upfront

local lsp = require("plugins.lsp.lsp")
local treeview = require("widgets.treeview")
local goto_loc = require("plugins.lsp.goto")

--- Convert a symbol (hierarchical DocumentSymbol or flat SymbolInformation)
--- into a tree node. Children are converted eagerly: one documentSymbol
--- request returns the whole tree, so no per-node fetching is needed.
---@param sym any symbol from the documentSymbol response
---@param fname string buffer file path (jump target)
---@return table node
local function make_node(sym, fname)
  local sel = sym.location and sym.location.range or sym.selectionRange or sym.range
  local lnum, col = lsp.to_vim_pos(sel.start)
  local children = {}
  for _, child in ipairs(sym.children or {}) do
    table.insert(children, make_node(child, fname))
  end
  return { name = sym.name, filename = fname, lnum = lnum, col = col, children = children }
end

local M = {}

--- Open the outline panel for the current buffer.
--- Repeated calls re-fetch symbols and refresh the panel.
function M.open()
  local bufnr = vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  local fname = vim.api.nvim_buf_get_name(bufnr)

  local client = lsp.start_request(bufnr, "textDocument/documentSymbol", 10000, function(req)
    local err, result = req.request(bufnr, "textDocument/documentSymbol", {
      textDocument = { uri = req.source.uri },
    })
    if err or not result or #result == 0 then
      vim.notify("[outline] no symbols", vim.log.levels.WARN)
      return
    end
    local root_nodes = {}
    for _, sym in ipairs(result) do
      table.insert(root_nodes, make_node(sym, fname))
    end

    local tree = treeview.create({
      viewId = "document_outline",  -- singleton: re-open reuses the panel
      title = "Outline",
      provider = {
        get_children = function(element, callback)
          callback(element and element.children or root_nodes)
        end,
        get_tree_item = function(element)
          return {
            label = element.name,
            collapsible = #element.children > 0,
            description = tostring(element.lnum),
          }
        end,
      },
      on_select = function(element)
        goto_loc.jump_to(source_win, {
          filename = element.filename,
          lnum = element.lnum,
          col = element.col,
        })
      end,
      expand_level = 1,  -- auto-expand top-level symbols
      icons = { collapsed = "+", expanded = "-" },
      position = "right",
    })
    tree.show()
  end, function(err)
    vim.notify("[outline] " .. err, vim.log.levels.WARN)
  end)
  if not client then
    vim.notify("[outline] no LSP client with document symbols", vim.log.levels.WARN)
  end
end

return M
