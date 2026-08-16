-- Auto-completion engine (hrsh7th/nvim-cmp)
--
-- Provides intelligent auto-completion with multiple sources:
-- 1. Sources (priority order):
--    - nvim_lsp: LSP-powered completions (functions, types, variables)
--    - luasnip: snippet expansions
--    - buffer: words from open buffers (fallback)
--    - path: filesystem path completions (fallback)
-- 2. Snippet engine: LuaSnip for LSP snippet expansion and placeholder jumping
-- 3. Keybindings:
--    <C-Space>  manually trigger completion menu
--    <CR>       confirm selected item
--    <Tab>      next item / expand snippet / jump to next placeholder
--    <S-Tab>    previous item / jump to previous placeholder

--- @type LazyPluginSpec[]
return {
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      -- LSP completion source
      "hrsh7th/cmp-nvim-lsp",
      -- Buffer words completion source
      "hrsh7th/cmp-buffer",
      -- Filesystem path completion source
      "hrsh7th/cmp-path",
      -- Snippet engine
      "L3MON4D3/LuaSnip",
      -- Bridge between LuaSnip and nvim-cmp
      "saadparwaiz1/cmp_luasnip",
    },
    config = function()
      --- @type cmp
      local cmp = require("cmp")
      --- @type luasnip
      local luasnip = require("luasnip")

      cmp.setup({
        -- Snippet expansion: how to expand LSP snippet text into editable placeholders
        snippet = {
          --- @param args {body: string} Snippet body text from LSP
          expand = function(args)
            -- Parse and expand the snippet body using LuaSnip
            luasnip.lsp_expand(args.body)
          end,
        },
        -- Keybinding configuration using nvim-cmp's built-in insert mode preset
        mapping = cmp.mapping.preset.insert({
          -- Trigger completion manually: force show completion menu even without typing
          ["<C-Space>"] = cmp.mapping.complete(),
          -- Confirm selection: accept the highlighted item and insert it
          ["<CR>"] = cmp.mapping.confirm({ select = true }),
          -- Next item or snippet jump: cycle forward in menu, or jump to next snippet placeholder
          ["<Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              -- Completion menu is open: move to next item
              cmp.select_next_item()
            elseif luasnip.expand_or_jumpable() then
              -- Inside a snippet: jump to next placeholder
              luasnip.expand_or_jump()
            else
              -- Nothing applicable: insert a literal tab
              fallback()
            end
          end, { "i", "s" }),
          -- Previous item or snippet jump back: cycle backward in menu, or jump to previous placeholder
          ["<S-Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              -- Completion menu is open: move to previous item
              cmp.select_prev_item()
            elseif luasnip.jumpable(-1) then
              -- Inside a snippet: jump to previous placeholder
              luasnip.jump(-1)
            else
              -- Nothing applicable: use default behavior
              fallback()
            end
          end, { "i", "s" }),
        }),
        -- Completion sources grouped by priority (first group tried first)
        sources = cmp.config.sources({
          -- Primary sources: LSP and snippets
          { name = "nvim_lsp" },
          { name = "luasnip" },
        }, {
          -- Fallback sources: used when primary sources return no results
          { name = "buffer" },
          { name = "path" },
        }),
      })
    end,
  },
}
