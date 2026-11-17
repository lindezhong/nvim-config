-- view.lua
-- Base view module for the git plugin's UI components.
-- A view represents a logical UI unit (e.g., a file list, a diff panel)
-- with its own buffer and lifecycle events. Views communicate state changes
-- via an event emitter pattern (on/emit), supporting open, close, focus,
-- and blur lifecycle hooks.

--- @type table Module table exported by this file
local M = {}

--- Create a new view instance.
-- The view starts with no buffer and an empty listener table. Consumers
-- should attach event listeners via :on() and trigger lifecycle methods
-- (open, close, focus, blur) to drive the view's behavior.
---@return table self The view instance with event and lifecycle methods
function M.create()
  --- @type table The view instance holding state and methods
  local self = {
    buf = nil,       -- The Neovim buffer handle associated with this view (set externally)
    listeners = {},  -- Map of event name -> list of listener functions
  }

  --- Register an event listener for the given event name.
  -- Multiple listeners can be registered for the same event and will be
  -- called in the order they were added.
  ---@param event string The event name to listen for (e.g., "open", "close", "focus", "blur")
  ---@param fn function The callback function to invoke when the event is emitted
  function self:on(event, fn)
    -- Initialize the listener list for this event if it does not exist
    if not self.listeners[event] then
      self.listeners[event] = {}
    end
    -- Append the listener function to the event's listener list
    self.listeners[event][#self.listeners[event] + 1] = fn
  end

  --- Emit an event, calling all registered listeners with the provided arguments.
  ---@param event string The event name to emit
  ---@param ... any Additional arguments to pass to each listener function
  function self:emit(event, ...)
    -- Retrieve the list of listeners for this event
    local fns = self.listeners[event]
    if fns then
      -- Invoke each listener in registration order
      for _, fn in ipairs(fns) do
        fn(...)
      end
    end
  end

  --- Trigger the "open" lifecycle event.
  -- Called when the view is being displayed/activated. Listeners should
  -- perform initialization such as populating the buffer.
  function self:open()
    self:emit("open")
  end

  --- Trigger the "close" lifecycle event and clean up the buffer.
  -- Emits the "close" event first so listeners can perform teardown,
  -- then deletes the associated buffer if it is still valid.
  function self:close()
    -- Emit "close" so listeners can perform cleanup before buffer deletion
    self:emit("close")
    -- Delete the view's buffer if it exists and is still valid
    if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
      vim.api.nvim_buf_delete(self.buf, { force = true })
    end
    -- Clear the buffer reference
    self.buf = nil
  end

  --- Trigger the "focus" lifecycle event.
  -- Called when the view's window gains focus. Listeners can update
  -- highlights, statusline, or other focus-dependent UI state.
  function self:focus()
    self:emit("focus")
  end

  --- Trigger the "blur" lifecycle event.
  -- Called when the view's window loses focus. Listeners can dim
  -- highlights or update UI state for the unfocused view.
  function self:blur()
    self:emit("blur")
  end

  return self
end

return M
