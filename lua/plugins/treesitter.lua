-- Treesitter configuration: syntax-tree based highlighting and parsing
--
-- This file sets up nvim-treesitter with the following:
-- 1. Parsers: auto-install for typescript, tsx, javascript, lua
-- 2. Highlighting: enables treesitter-based syntax highlighting per buffer
--    (replaces regex-based highlighting with accurate syntax-tree coloring)

return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    lazy = false,
    build = ":TSUpdate",
    config = function()
      -- Install language parsers
      require("nvim-treesitter").install({
        "typescript", "tsx", "javascript", "lua",
      })

      -- Enable treesitter highlighting for supported filetypes
      vim.api.nvim_create_autocmd("FileType", {
        callback = function(args)
          local lang = vim.treesitter.language.get_lang(args.match)
          if lang then
            pcall(vim.treesitter.start, args.buf, lang)
          end
        end,
      })
    end,
  },
}
