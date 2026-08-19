-- Comment toggling (numToStr/Comment.nvim)
--
-- Toggle comments with treesitter-aware context for mixed-language files
-- (e.g. JSX where JS uses // and HTML uses <!-- -->).
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
  -- Treesitter-based commentstring detection for mixed-language files
  {
    "JoosepAlviste/nvim-ts-context-commentstring",
    lazy = true,
    opts = {
      enable_autocmd = false,
    },
  },
  -- Comment plugin
  {
    "numToStr/Comment.nvim",
    event = "VeryLazy",
    dependencies = { "JoosepAlviste/nvim-ts-context-commentstring" },
    config = function()
      require("Comment").setup({
        -- Use treesitter to determine commentstring (handles JSX, Vue, etc.)
        pre_hook = require("ts_context_commentstring.integrations.comment_nvim").create_pre_hook(),
      })
    end,
  },
}
