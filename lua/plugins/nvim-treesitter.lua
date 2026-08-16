-- Syntax highlighting via tree-sitter parsing (nvim-treesitter/nvim-treesitter)
--
-- Provides accurate syntax highlighting by building a concrete syntax tree (CST)
-- for each buffer, replacing vim's regex-based highlighting with structural parsing.
--
-- 1. Parsers: auto-install grammars for typescript, tsx, javascript, lua
-- 2. Highlighting: attach treesitter highlighter on FileType for supported languages
--
-- :TSInstall <lang>   install a new language parser
-- :TSUpdate           update all installed parsers

--- @type LazyPluginSpec[]
return {
  {
    "nvim-treesitter/nvim-treesitter",
    -- Use main branch (required for the new module-based API)
    branch = "main",
    -- Load immediately (highlighting must be active from startup)
    lazy = false,
    -- Run :TSUpdate after install/update to compile parsers
    build = ":TSUpdate",
    config = function()
      --- @type string[] Language parsers to auto-install on first launch
      local ensure_installed = { "typescript", "tsx", "javascript", "lua" }
      -- Download and compile parsers for the specified languages
      require("nvim-treesitter").install(ensure_installed)

      -- Attach treesitter highlighter whenever a supported filetype is opened
      vim.api.nvim_create_autocmd("FileType", {
        --- @param args {match: string, buf: number} Autocmd callback arguments
        callback = function(args)
          -- Map filetype to treesitter language name (e.g. "javascriptreact" -> "javascript")
          --- @type string|nil
          local lang = vim.treesitter.language.get_lang(args.match)
          if lang then
            -- Start treesitter highlighting for this buffer (pcall to silently skip if parser unavailable)
            pcall(vim.treesitter.start, args.buf, lang)
          end
        end,
      })
    end,
  },
}
