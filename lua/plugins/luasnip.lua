-- Snippet engine (L3MON4D3/LuaSnip)
--
-- Provides snippet expansion, placeholder jumping, and dynamic node evaluation.
-- Acts as the backend for nvim-cmp snippet completions.
--
-- Snippet sources (loaded in order):
--   1. Lua snippets:     lua/snippets/{filetype}.lua  (dynamic, postfix)
--   2. SnipMate custom:  snippets/{filetype}/*.snippets  (converted from UltiSnips)
--   3. SnipMate community: honza/vim-snippets (installed via lazy.nvim)
--
-- Lua snippet file format (lua/snippets/*.lua):
--   return {
--     s({ trig = "trigger", name = "Name", desc = "Description" }, { nodes... }),
--   }

--- @type LazyPluginSpec[]
return {
  {
    "L3MON4D3/LuaSnip",
    dependencies = {
      "rafamadriz/friendly-snippets", -- Community snippet collection (VSCode JSON format)
    },
    config = function()
      --- @type luasnip
      local luasnip = require("luasnip")

      luasnip.setup({
        -- Re-evaluate dynamic/function nodes on every text change (like UltiSnips)
        update_events = { "TextChanged", "TextChangedI" },
        -- Auto-leave snippet session when cursor moves outside the snippet region.
        -- Prevents locally_jumpable() from returning true for abandoned snippets.
        region_check_events = "CursorMoved",
      })

      -- jsx files inherit javascript snippets
      luasnip.filetype_extend("javascriptreact", { "javascript" })

      -- Load custom Lua snippets (supports function_node, dynamic_node, postfix)
      require("luasnip.loaders.from_lua").lazy_load({
        paths = { vim.fn.stdpath("config") .. "/lua/snippets" },
      })

      -- Load custom SnipMate-format snippets (converted from UltiSnips)
      require("luasnip.loaders.from_snipmate").lazy_load({
        paths = { vim.fn.stdpath("config") .. "/snippets" },
      })

      -- Load community snippets from rafamadriz/friendly-snippets (VSCode JSON format)
      require("luasnip.loaders.from_vscode").lazy_load()
    end,
  },
}
