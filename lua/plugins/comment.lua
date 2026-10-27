-- Comment toggling (numToStr/Comment.nvim)
--
-- Toggle comments with language-aware commentstring.
--
-- Key mappings (default):
--   gcc       toggle line comment (normal)
--   gbc       toggle block comment (normal)
--   gc        toggle line comment (visual)
--   gb        toggle block comment (visual)
--   gcO       add comment on line above
--   gco       add comment on line below
--   gcA       add comment at end of line
--
-- Supports count: 3gcc comments 3 lines

--- @type LazyPluginSpec[]
return {
  {
    "numToStr/Comment.nvim",
    event = "VeryLazy",
    config = function()
      require("Comment").setup({})
    end,
  },
}
