-- Auto-completion engine configuration
--
-- This file sets up nvim-cmp with the following:
-- 1. Completion sources (priority order):
--    - nvim_lsp: LSP-powered intelligent completions
--    - luasnip: snippet expansions
--    - buffer: words from open buffers (fallback)
--    - path: filesystem path completions (fallback)
-- 2. Snippet: LuaSnip as the snippet engine for LSP snippet support
-- 3. Keybindings:
--    <C-Space>  manually trigger completion
--    <CR>       confirm selected item
--    <Tab>      next item / expand snippet / jump forward
--    <S-Tab>    previous item / jump backward

return {
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "hrsh7th/cmp-buffer",
      "hrsh7th/cmp-path",
      "L3MON4D3/LuaSnip",
      "saadparwaiz1/cmp_luasnip",
    },
    config = function()
      local cmp = require("cmp")
      local luasnip = require("luasnip")

      cmp.setup({
        -- Snippet expansion handler
        snippet = {
          expand = function(args)
            luasnip.lsp_expand(args.body)
          end,
        },
        mapping = cmp.mapping.preset.insert({
          -- Trigger completion manually: force show completion menu even without typing
          ["<C-Space>"] = cmp.mapping.complete(),
          -- Confirm selection: accept the highlighted item and insert it
          ["<CR>"] = cmp.mapping.confirm({ select = true }),
          -- Next item or snippet jump: cycle forward in menu, or jump to next snippet placeholder
          ["<Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_next_item()
            elseif luasnip.expand_or_jumpable() then
              luasnip.expand_or_jump()
            else
              fallback()
            end
          end, { "i", "s" }),
          -- Previous item or snippet jump back: cycle backward in menu, or jump to previous placeholder
          ["<S-Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_prev_item()
            elseif luasnip.jumpable(-1) then
              luasnip.jump(-1)
            else
              fallback()
            end
          end, { "i", "s" }),
        }),
        sources = cmp.config.sources({
          -- Primary sources
          { name = "nvim_lsp" },
          { name = "luasnip" },
        }, {
          -- Fallback sources
          { name = "buffer" },
          { name = "path" },
        }),
      })
    end,
  },
}
