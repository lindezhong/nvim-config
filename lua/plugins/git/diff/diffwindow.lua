-- diffwindow.lua
-- Manages the full diff window UI including the file tree panel and diff panes.
-- Provides a split-window layout with a navigable tree of changed files on the left
-- and diff content (vimdiff or unified) on the right. Supports toggling between
-- vimdiff and unified modes, refreshing the file list, and keyboard-driven navigation.

--- @module plugins.git.diff.diffwindow

-- Import the window manager for creating the overall window container
local window = require("widgets.window")
-- Import horizontal layout module for arranging panes side by side
local hlayout = require("widgets.hlayout")
-- Import the treeview widget for rendering the file tree
local treeview = require("widgets.treeview")
-- Import diffview for rendering actual diff content in buffers
local diffview = require("plugins.git.diff.diffview")
-- Import the git module for file operations and status queries
local git = require("plugins.git.git")

-- Alias for the Neovim API namespace
local api = vim.api
--- @type table Module table exported by this file
local M = {}

--- @type table|nil Holds the current diff window state (nil when closed)
local state = nil

--- Mapping of git status codes to highlight group names for the tree display
--- @type table<string, string>
local status_hl = {
  M = "GitModified",   -- Modified files
  A = "GitAdded",      -- Added (new) files
  D = "GitDeleted",    -- Deleted files
  R = "GitRenamed",    -- Renamed files
  U = "GitUntracked",  -- Untracked files
}

--- Map git raw status codes to standard display characters.
-- Translates internal git status indicators to user-friendly icons.
--- @type table<string, string>
local status_icon = {
  ["?"] = "U",  -- untracked files shown as "U"
}

--- Build a tree structure from a flat list of changed files.
-- Groups files by directory and applies path compression (merging single-child
-- directories into combined path segments like "a/b/c").
-- @param files table[] List of file entries with path, status, and staged fields
-- @return table[] Tree nodes wrapped in a root node showing the working directory
local function build_tree(files)
  -- Cache of directory path strings to their corresponding tree nodes
  local dirs = {}
  -- Top-level children list (root of the tree)
  local children = {}

  -- Build the raw tree by splitting each file path into directory segments
  for _, file in ipairs(files) do
    -- Split the file path on "/" to get individual path components
    local parts = vim.split(file.path, "/")
    -- Start at the top-level children list
    local parent = children
    -- Create directory nodes for each intermediate path component
    for i = 1, #parts - 1 do
      -- Reconstruct the directory path up to this level
      local dir_path = table.concat(parts, "/", 1, i)
      if not dirs[dir_path] then
        -- Create a new directory node with an empty children list
        local dir_node = {
          name = parts[i],
          children = {},
        }
        -- Register this directory in the lookup table
        dirs[dir_path] = dir_node
        -- Add to the current parent's children
        parent[#parent + 1] = dir_node
      end
      -- Descend into this directory's children for the next level
      parent = dirs[dir_path].children
    end
    -- Add the file node (leaf) as the final path component
    parent[#parent + 1] = {
      name = parts[#parts],
      path = file.path,
      status = file.status,
      staged = file.staged,
    }
  end

  -- Path compression: merge single-child directories into combined names.
  -- For example, "src" -> "utils" -> "helpers" becomes "src/utils/helpers"
  -- when each intermediate directory has only one child that is also a directory.
  local function compress(nodes)
    for i, node in ipairs(nodes) do
      if node.children then
        -- Keep merging while the directory has exactly one child that is also a directory
        while #node.children == 1 and node.children[1].children do
          local child = node.children[1]
          -- Combine the parent and child directory names
          node.name = node.name .. "/" .. child.name
          -- Adopt the grandchildren as direct children
          node.children = child.children
        end
        -- Recursively compress deeper levels
        compress(node.children)
      end
    end
  end
  -- Apply path compression to the top-level children
  compress(children)

  -- Sort nodes: directories first, then alphabetically by name
  local function sort_nodes(nodes)
    table.sort(nodes, function(a, b)
      -- Determine if each node is a directory (has children)
      local a_dir = a.children ~= nil
      local b_dir = b.children ~= nil
      -- Directories come before files
      if a_dir ~= b_dir then
        return a_dir
      end
      -- Within the same type, sort alphabetically
      return a.name < b.name
    end)
    -- Recursively sort children of directories
    for _, node in ipairs(nodes) do
      if node.children then
        sort_nodes(node.children)
      end
    end
  end
  -- Apply sorting to the entire tree
  sort_nodes(children)

  -- Wrap in a root node showing the working directory path (shortened with ~)
  local cwd = vim.fn.fnamemodify(git.root() or vim.fn.getcwd(), ":~")
  local root = { { name = cwd, children = children } }
  return root
end

--- Create a treeview widget from tree nodes.
-- Configures the tree with display options including status icons and highlight groups.
-- @param tree_nodes table[] The tree structure to display
-- @param current table|nil The node to set as initially selected
-- @return table The created treeview widget instance
local function create_tree(tree_nodes, current)
  return treeview.create({
    -- The tree data to render
    items = tree_nodes,
    -- Callback to convert a tree element into display properties
    get_tree_item = function(element)
      -- Check if this element is a directory (has children)
      local is_dir = element.children ~= nil
      -- Determine the icon text: map raw status to display character
      local icon_text = element.status and (status_icon[element.status] or element.status) or nil
      return {
        -- Display name for this tree item
        label = element.name,
        -- Directories are collapsible, files are not
        collapsible = is_dir,
        -- Show status icon with appropriate highlight for files
        icon = icon_text and { text = icon_text, hlGroup = status_hl[icon_text] or "" } or nil,
        -- Directories use the "Directory" highlight group
        label_hl = is_dir and "Directory" or nil,
      }
    end,
    -- Expand all nodes by default (level 99 effectively means all)
    expand_level = 99,
    -- Set the initially selected/current node
    current = current,
  })
end

--- Wire up event handlers and keymaps on the tree widget.
-- Configures selection behavior (show diff on file select), cursor movement
-- behavior (preview diff after delay), and keyboard shortcuts.
-- @param tree table The treeview widget to configure
local function wire_tree(tree)
  -- Handle explicit selection (Enter key) on a tree node
  tree:on("select", function(element)
    if element.children then
      -- Toggle expand/collapse for directories
      tree:toggle(element)
    else
      -- For files, stop the debounce timer and show the diff immediately
      state.cursor_timer:stop()
      M._show_file(element)
      -- Move focus to the diff window (new pane in vimdiff, diff pane in unified)
      local target_win = state.win.layout:get(state.mode == "vimdiff" and "new" or "diff")
      if target_win and api.nvim_win_is_valid(target_win) then
        api.nvim_set_current_win(target_win)
      end
    end
  end)

  -- Handle cursor movement over tree nodes (preview with debounce)
  tree:on("cursor", function(element)
    if not element.children then
      -- Stop any pending preview timer
      state.cursor_timer:stop()
      -- Start a new 50ms debounce timer before showing the diff preview
      state.cursor_timer:start(50, 0, vim.schedule_wrap(function()
        -- Guard against state being cleared during the timer delay
        if not state then return end
        -- Show the diff for the file under the cursor
        M._show_file(element)
      end))
    end
  end)

  -- Set up keymaps for the tree buffer
  -- "q" closes the diff window
  vim.keymap.set("n", "q", function() M.close() end, { buffer = tree.buf, silent = true })
  -- "u" toggles between vimdiff and unified modes
  vim.keymap.set("n", "u", function() M.toggle_mode() end, { buffer = tree.buf, silent = true })
  -- "R" refreshes the file list (re-queries git)
  vim.keymap.set("n", "R", function() M.refresh() end, { buffer = tree.buf, silent = true })
end

--- Configure window options for the tree panel.
-- Applies visual settings appropriate for a file tree sidebar.
-- @param win integer|nil The window ID to configure
-- @param buf integer The buffer to display in the window
local function setup_tree_win(win, buf)
  if win and api.nvim_win_is_valid(win) then
    -- Set the tree buffer into the window
    api.nvim_win_set_buf(win, buf)
    -- Disable line numbers for a cleaner tree appearance
    vim.wo[win].number = false
    -- Disable relative line numbers
    vim.wo[win].relativenumber = false
    -- Hide the sign column
    vim.wo[win].signcolumn = "no"
    -- Hide the fold column
    vim.wo[win].foldcolumn = "0"
    -- Disable line wrapping so long paths don't wrap
    vim.wo[win].wrap = false
    -- Enable cursor line highlighting for better visibility
    vim.wo[win].cursorline = true
  end
end

--- @class DiffWindowOpts
--- @field files table[] List of changed files to display
--- @field ref1 string? Git ref for the old (left) side
--- @field ref2 string? Git ref for the new (right) side
--- @field cached boolean? Whether to show staged (cached) changes
--- @field mode "vimdiff"|"unified" Display mode
--- @field path string? Optional path filter
--- @field current_file string? File path to select initially (falls back to first file)
--- @field refresh_fn function? Custom function to refresh the file list
--- @field on_close function? Callback invoked when the diff window is closed

--- Open the diff window with the given options.
-- Creates the full layout (tree + diff panes), populates the tree with files,
-- and displays the diff for the first file.
---@param opts DiffWindowOpts Options controlling what to display
function M.open(opts)
  -- Close any existing diff window before opening a new one
  if state then
    M.close()
  end

  -- Determine the display mode (default to vimdiff)
  local mode = opts.mode or "vimdiff"
  -- Get the list of files to show
  local files = opts.files
  -- If there are no files, notify the user and exit
  if #files == 0 then
    vim.notify("No files to diff", vim.log.levels.INFO)
    return
  end

  -- Create the window with the appropriate layout based on mode
  local win = window.create(function()
    if mode == "vimdiff" then
      -- Three-pane layout: tree (30% width) | old | new
      return hlayout.create({ { width = "30%", name = "tree" }, { name = "old" }, { name = "new" } })
    else
      -- Two-pane layout: tree (30% width) | diff
      return hlayout.create({ { width = "30%", name = "tree" }, { name = "diff" } })
    end
  end)
  -- Open the window (makes it visible)
  win:open()

  -- Build the file tree from the flat file list
  local tree_nodes = build_tree(files)

  -- Find a file node by path, or fall back to the first non-directory node
  local function find_file(nodes, target_path)
    for _, node in ipairs(nodes) do
      if not node.children then
        if target_path and node.path == target_path then
          return node
        end
      else
        local found = find_file(node.children, target_path)
        if found then return found end
      end
    end
  end
  local function find_first_file(nodes)
    for _, node in ipairs(nodes) do
      if not node.children then
        return node
      else
        local found = find_first_file(node.children)
        if found then return found end
      end
    end
  end
  local first_file = (opts.current_file and find_file(tree_nodes, opts.current_file))
    or find_first_file(tree_nodes)

  -- Create the treeview widget with the first file pre-selected
  local tree = create_tree(tree_nodes, first_file)
  -- Create a diffview instance for managing diff buffers
  local diff = diffview.create()

  -- Place the tree buffer into the tree window pane
  setup_tree_win(win.layout:get("tree"), tree.buf)

  -- Initialize the module-level state with all components
  state = {
    win = win,               -- The window container
    tree = tree,             -- The treeview widget
    diff = diff,             -- The diffview instance
    opts = opts,             -- The original options
    mode = mode,             -- Current display mode
    cursor_timer = vim.uv.new_timer(),  -- Timer for debounced cursor preview
  }

  -- Wire up event handlers and keymaps on the tree
  wire_tree(tree)

  -- Show the diff for the first file immediately
  if first_file then
    M._show_file(first_file)
  end

  -- Focus the tree window (use noautocmd to avoid interfering with diff scrollbind)
  local tree_win = win.layout:get("tree")
  if tree_win and api.nvim_win_is_valid(tree_win) then
    vim.cmd("noautocmd call win_gotoid(" .. tree_win .. ")")
  end
end

--- Show the diff for a specific file element.
-- Internal function called when the user selects or hovers over a file in the tree.
-- Skips if the file is already displayed or if the path points to a directory.
---@param element table A file node from the tree with a path field
function M._show_file(element)
  -- Guard: state must exist and element must have a path
  if not state or not element.path then
    return
  end

  -- Skip if this file is already being displayed (avoid redundant redraws)
  if state.current_path == element.path then
    return
  end

  -- Skip directories (they cannot be diffed)
  local root = git.root() or ""
  local abs_path = root .. "/" .. element.path
  if vim.fn.isdirectory(abs_path) == 1 then
    return
  end

  -- Record the current path to prevent duplicate displays
  state.current_path = element.path

  -- Dispatch to the appropriate diff display function based on mode
  local opts = state.opts
  if state.mode == "vimdiff" then
    -- Show side-by-side diff in the old and new windows
    diffview.show_vimdiff(state.diff, {
      ref1 = opts.ref1 or (opts.cached and "HEAD" or nil),
      ref2 = opts.ref2,
      path = element.path,
      cached = opts.cached,
      win_old = state.win.layout:get("old"),
      win_new = state.win.layout:get("new"),
    })
  else
    -- Show unified diff in the single diff window
    diffview.show_unified(state.diff, {
      ref1 = opts.ref1,
      ref2 = opts.ref2,
      path = element.path,
      cached = opts.cached,
      win = state.win.layout:get("diff"),
    })
  end
end

--- Toggle between vimdiff and unified display modes.
-- Clears the current diff, rebuilds the layout for the new mode,
-- and re-attaches the tree widget.
function M.toggle_mode()
  -- Guard: do nothing if no diff window is open
  if not state then
    return
  end

  -- Stop any pending cursor timer
  state.cursor_timer:stop()
  -- Determine the new mode (opposite of current)
  local new_mode = state.mode == "vimdiff" and "unified" or "vimdiff"

  -- Reset current path so the next file selection will trigger a redraw
  state.current_path = nil
  -- Clear all diff buffers
  diffview.clear(state.diff)

  -- The rebuild closes the old tree window; treeview created the tree buffer
  -- with bufhidden="wipe", so that close would delete it before it is
  -- re-attached below. The flag stays cleared afterwards: the buffer lives
  -- on in the rebuilt tree window, and final teardown still deletes it
  -- explicitly (tree:close -> dispose).
  vim.bo[state.tree.buf].bufhidden = ""

  -- Rebuild the window layout for the new mode
  state.win:rebuild_layout(function()
    if new_mode == "vimdiff" then
      -- Three-pane layout: tree (30% width) | old | new
      return hlayout.create({ { width = "30%", name = "tree" }, { name = "old" }, { name = "new" } })
    else
      -- Two-pane layout: tree (30% width) | diff
      return hlayout.create({ { width = "30%", name = "tree" }, { name = "diff" } })
    end
  end)
  -- Get the newly created layout
  local layout = state.win.layout

  -- Re-attach the tree buffer to the tree window in the new layout
  setup_tree_win(layout:get("tree"), state.tree.buf)

  -- Update the mode in state
  state.mode = new_mode

  -- Focus the tree window after mode switch
  local tree_win = layout:get("tree")
  if tree_win and api.nvim_win_is_valid(tree_win) then
    api.nvim_set_current_win(tree_win)
  end
end

--- Refresh the file list by re-querying git.
-- Uses the refresh_fn if provided, otherwise falls back to git.diff_files.
-- Rebuilds the tree widget with the updated file list.
function M.refresh()
  -- Guard: do nothing if no diff window is open
  if not state then
    return
  end
  -- Reset current path so the refreshed tree can show any file
  state.current_path = nil
  local opts = state.opts
  -- Get the updated file list
  local new_files
  if opts.refresh_fn then
    -- Use the custom refresh function if provided
    new_files = opts.refresh_fn()
  else
    -- Otherwise query git for diff files with the same options
    new_files = git.diff_files({
      ref1 = opts.ref1,
      ref2 = opts.ref2,
      cached = opts.cached,
      path = opts.path,
    })
  end
  -- Update the stored files list
  opts.files = new_files

  -- Close the old tree widget (cleans up buffer and autocmds)
  state.tree:close()

  -- Build a new tree from the updated file list
  local tree_nodes = build_tree(new_files)
  -- Create a new tree widget (no pre-selected file)
  local tree = create_tree(tree_nodes)
  -- Store the new tree in state
  state.tree = tree

  -- Place the new tree buffer into the tree window
  local tree_win = state.win.layout:get("tree")
  if tree_win and api.nvim_win_is_valid(tree_win) then
    api.nvim_win_set_buf(tree_win, tree.buf)
  end

  -- Wire up event handlers and keymaps on the new tree
  wire_tree(tree)
end

--- Close the diff window and clean up all resources.
-- Stops timers, clears diff buffers, closes the tree, and destroys the window.
-- Invokes the on_close callback if one was provided.
function M.close()
  -- Guard: do nothing if no diff window is open
  if not state then
    return
  end

  -- Save the on_close callback before clearing state
  local on_close = state.opts.on_close
  -- Move state to a local variable and clear the module-level state
  local s = state
  state = nil

  -- Stop and close the cursor debounce timer
  if s.cursor_timer then
    s.cursor_timer:stop()
    s.cursor_timer:close()
  end
  -- Clear diff buffers (wrapped in pcall for safety)
  pcall(diffview.clear, s.diff)
  -- Close the tree widget (wrapped in pcall for safety)
  pcall(function() s.tree:close() end)
  -- Close the window container (destroys all panes)
  s.win:close()

  -- Invoke the on_close callback if provided
  if on_close then
    on_close()
  end
end

--- Check whether the diff window is currently open.
-- @return boolean True if the diff window is open, false otherwise
function M.is_open()
  return state ~= nil
end

return M
