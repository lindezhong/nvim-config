-- layout.lua
-- Base layout module for the git plugin's window management system.
-- Provides a factory function to create layout objects that track windows,
-- buffers, and a shared name registry. Layouts can form a tree structure
-- via child layouts, enabling composite (nested) window arrangements.

--- Neovim API shorthand for window/buffer operations
local api = vim.api

--- @type table Module table exported by this file
local M = {}

--- Create a new base layout instance.
-- A layout tracks its own windows and buffers, maintains a shared name
-- registry for looking up windows by logical name, and optionally manages
-- child layouts to form a composite tree.
---@param registry? table Shared name registry (nil = create new root registry)
---@return table self The layout instance with methods for lifecycle management
function M.create(registry)
  -- Use the provided registry or initialize a new empty one for root layouts
  registry = registry or {}

  --- @type table The layout instance holding state and methods
  local self = {
    wins = {},        -- List of window handles owned directly by this layout
    bufs = {},        -- List of buffer handles owned directly by this layout
    registry = registry, -- Shared name->window mapping across the layout tree
    children = nil,   -- Optional list of child layout instances (nil if leaf)
  }

  --- Destroy this layout and all its children.
  -- Recursively destroys child layouts first, then closes all owned windows,
  -- resets internal state, and clears the shared registry so no stale handles
  -- can be retrieved via :get().
  function self:destroy()
    -- Recursively destroy all child layouts if any exist
    if self.children then
      for _, child in ipairs(self.children) do
        child:destroy()
      end
    end
    -- Close all windows owned directly by this layout
    for _, win in ipairs(self.wins) do
      if api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true) -- force close even if modified
      end
    end
    -- Reset all internal state
    self.wins = {}
    self.bufs = {}
    self.children = nil
    -- Clear all name->win mappings so stale handles cannot be retrieved via :get()
    for k in pairs(self.registry) do
      self.registry[k] = nil
    end
  end

  --- Check whether this layout (and all children) are still valid.
  -- A layout is valid only if every window it owns (directly or through
  -- children) is still a valid Neovim window handle.
  ---@return boolean true if all windows in the layout tree are valid
  function self:is_valid()
    -- If this layout has children, delegate validity check to each child
    if self.children then
      for _, child in ipairs(self.children) do
        if not child:is_valid() then
          return false
        end
      end
      return true
    end
    -- Leaf layout: check each directly-owned window handle
    for _, win in ipairs(self.wins) do
      if not api.nvim_win_is_valid(win) then
        return false
      end
    end
    return true
  end

  --- Register a logical name for a window in the shared registry.
  -- Asserts that the name is not already taken to prevent accidental collisions.
  ---@param name string The unique logical name to assign to the window
  ---@param win integer The Neovim window handle to associate with the name
  function self:register(name, win)
    assert(not self.registry[name], "duplicate layout name: " .. name)
    self.registry[name] = win
  end

  --- Get a window handle by its logical name from the shared registry.
  ---@param name string The logical name previously registered
  ---@return integer? win The window handle, or nil if not found
  function self:get(name)
    return self.registry[name]
  end

  --- Recursively rebind the registry reference for a subtree.
  -- Used internally when adding a child layout so that the child (and all
  -- its descendants) share the same registry table as the parent.
  ---@param node table A layout node whose registry should be replaced
  ---@param reg table The new registry table to assign
  local function rebind_registry(node, reg)
    -- Point this node's registry to the new shared registry
    node.registry = reg
    -- Recurse into children if any exist
    if node.children then
      for _, c in ipairs(node.children) do
        rebind_registry(c, reg)
      end
    end
  end

  --- Add a child layout, merging its registry entries into the parent's.
  -- After calling this, the child's registry is rebound to share the parent's
  -- registry, so all name lookups across the tree use a single table.
  ---@param child table A layout instance to adopt as a child
  function self:add_child(child)
    -- Initialize the children list on first use
    if not self.children then
      self.children = {}
    end
    -- Merge child's existing registry entries into the parent registry
    for name, win in pairs(child.registry) do
      assert(not self.registry[name], "duplicate layout name: " .. name)
      self.registry[name] = win
    end
    -- Rebind the child subtree to share the parent's registry reference
    rebind_registry(child, self.registry)
    -- Append the child to the children list
    self.children[#self.children + 1] = child
  end

  --- Collect all window handles from this layout tree (recursively).
  -- For composite layouts, traverses children; for leaf layouts, returns
  -- the directly-owned window list.
  ---@return integer[] result Flat list of all window handles in the tree
  function self:get_all_wins()
    local result = {}
    if self.children then
      -- Gather windows from each child layout recursively
      for _, child in ipairs(self.children) do
        local child_wins = child:get_all_wins()
        for _, w in ipairs(child_wins) do
          result[#result + 1] = w
        end
      end
    else
      -- Leaf layout: collect directly-owned windows
      for _, w in ipairs(self.wins) do
        result[#result + 1] = w
      end
    end
    return result
  end

  return self
end

return M
