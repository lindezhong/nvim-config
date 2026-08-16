-- Auto-completion engine (hrsh7th/nvim-cmp)
--
-- Provides intelligent auto-completion popup with multiple sources.
-- Integrates with LuaSnip for snippet expansion and placeholder navigation.
--
-- Sources (priority order):
--   1. nvim_lsp  — LSP-powered completions (functions, types, variables)
--   2. luasnip   — snippet trigger completions
--   3. buffer    — words from open buffers (fallback)
--   4. path      — filesystem path completions (fallback)
--
-- Keybindings:
--   <C-Space>  manually trigger completion menu
--   <CR>       confirm selected item (expands snippet if selected)
--   <Tab>      jump to next snippet placeholder / next cmp item / expand / fallback
--   <S-Tab>    jump to prev snippet placeholder / prev cmp item / fallback

--- @type LazyPluginSpec[]
return {
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",    -- LSP completion source
      "hrsh7th/cmp-buffer",      -- Buffer words completion source
      "hrsh7th/cmp-path",        -- Filesystem path completion source
      "L3MON4D3/LuaSnip",       -- Snippet engine (config in lua/plugins/luasnip.lua)
      "saadparwaiz1/cmp_luasnip", -- Bridge between LuaSnip and nvim-cmp
    },
    config = function()
      --- @type cmp
      local cmp = require("cmp")
      --- @type luasnip
      local luasnip = require("luasnip")

      cmp.setup({
        -- Snippet expansion handler: called when a snippet item is confirmed.
        -- Delegates to LuaSnip to parse the LSP snippet body into editable nodes.
        snippet = {
          --- @param args {body: string} LSP snippet body text
          expand = function(args)
            luasnip.lsp_expand(args.body)
          end,
        },

        -- Keybinding configuration
        mapping = cmp.mapping.preset.insert({
          -- Manually trigger the completion popup
          ["<C-Space>"] = cmp.mapping.complete(),

          -- Confirm the currently selected (or first) completion item.
          -- If the item is a snippet, this triggers expansion.
          ["<CR>"] = cmp.mapping.confirm({ select = true }),

          -- Tab priority: snippet jump > cmp selection > snippet expand > literal tab
          ["<Tab>"] = cmp.mapping(function(fallback)
            if luasnip.locally_jumpable(1) then
              -- Inside an active snippet region: jump to next placeholder
              luasnip.jump(1)
            elseif cmp.visible() then
              -- Completion menu is open: select next item
              cmp.select_next_item()
            elseif luasnip.expandable() then
              -- Not in snippet, no menu, but cursor on a trigger: expand it
              luasnip.expand()
            else
              -- No snippet active, no menu, no trigger: insert literal tab
              fallback()
            end
          end, { "i", "s" }),

          -- S-Tab priority: snippet jump back > cmp selection back > literal S-Tab
          ["<S-Tab>"] = cmp.mapping(function(fallback)
            if luasnip.locally_jumpable(-1) then
              -- Inside an active snippet region: jump to previous placeholder
              luasnip.jump(-1)
            elseif cmp.visible() then
              -- Completion menu is open: select previous item
              cmp.select_prev_item()
            else
              -- No snippet active, no menu: default behavior
              fallback()
            end
          end, { "i", "s" }),
        }),

        -- Menu item formatting: append snippet description to the menu column.
        -- Truncates long descriptions to prevent the popup from becoming too wide.
        formatting = {
          --- @param entry cmp.Entry  The completion entry being formatted
          --- @param vim_item vim.CompletedItem  The item to display in the menu
          --- @return vim.CompletedItem
          format = function(entry, vim_item)
            -- Only enrich items from the luasnip source
            if entry.source.name == "luasnip" then
              -- Retrieve the internal snippet ID from the completion data
              local snip_id = entry.completion_item.data and entry.completion_item.data.snip_id
              if snip_id then
                -- Safely fetch the snippet object by ID
                local ok, snip = pcall(require("luasnip").get_id_snippet, snip_id)
                if ok and snip then
                  --- @type string|string[]
                  local desc = snip.description
                  -- Description may be a table of lines; join into single string
                  if type(desc) == "table" then desc = table.concat(desc, " ") end
                  if desc and desc ~= "" then
                    -- Non-ASCII (CJK etc) chars are wider; use shorter limit
                    local max = desc:find("[^\032-\126]") and 20 or 40
                    -- Truncate by unicode character count (not bytes) to avoid
                    -- cutting multi-byte characters in the middle
                    if vim.fn.strchars(desc) > max then
                      desc = vim.fn.strcharpart(desc, 0, max - 1) .. "…"
                    end
                    vim_item.menu = desc
                  end
                end
              end
            end
            return vim_item
          end,
        },

        -- Completion sources: first group has higher priority.
        -- If first group yields results, second group is not queried.
        sources = cmp.config.sources({
          { name = "nvim_lsp" },  -- LSP completions (highest priority)
          { name = "luasnip" },   -- Snippet triggers
        }, {
          { name = "buffer" },    -- Buffer words (fallback)
          { name = "path" },      -- File paths (fallback)
        }),
      })
    end,
  },
}
