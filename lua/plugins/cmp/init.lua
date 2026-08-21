-- Auto-completion engine (hrsh7th/nvim-cmp)
--
-- Provides intelligent auto-completion popup with multiple sources.
-- Integrates with LuaSnip for snippet expansion and placeholder navigation.
--
-- Sources are split into two priority groups (nvim-cmp's "fallback" pattern):
-- nvim-cmp queries group 2 ONLY when group 1 returns zero results.
--   Group 1: nvim_lsp, luasnip   — primary, always tried first
--   Group 2: buffer, path        — fallback when LSP/snippets yield nothing
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
      "L3MON4D3/LuaSnip",       -- Snippet engine (config in lua/plugins/luasnip.lua)
      "saadparwaiz1/cmp_luasnip", -- Bridge between LuaSnip and nvim-cmp
    },
    config = function()
      -- Advertise cmp completion capabilities to all LSP servers
      -- (enables snippet support, additional text edits, etc.)
      -- NOTE: this requires nvim-cmp to load before LSP servers start (must NOT be lazy-loaded)
      local capabilities = require("cmp_nvim_lsp").default_capabilities()
      vim.lsp.config("*", { capabilities = capabilities })

      --- @type cmp
      local cmp = require("cmp")
      -- Register the custom path source (replaces external hrsh7th/cmp-path plugin).
      -- See lua/plugins/cmp/path.lua for the implementation.
      cmp.register_source("path", require("plugins.cmp.path").new())
      cmp.register_source("dict", require("plugins.cmp.dict"))
      --- @type luasnip
      local luasnip = require("luasnip")

      -- Matched characters in popup highlighted blue (same as coc's CocSearch)
      local function set_cmp_hl()
        vim.api.nvim_set_hl(0, "CmpItemAbbrMatch", { ctermfg = "Blue" })
        vim.api.nvim_set_hl(0, "CmpItemAbbrMatchFuzzy", { ctermfg = "Blue" })
      end
      set_cmp_hl()
      vim.api.nvim_create_autocmd("ColorScheme", { callback = set_cmp_hl })

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

        formatting = {
          --- @param entry cmp.Entry  The completion entry being formatted
          --- @param vim_item vim.CompletedItem  The item to display in the menu
          --- @return vim.CompletedItem
          format = function(entry, vim_item)
            local detail = vim_item.menu
            if entry.source.name == "luasnip" then
              local snip_id = entry.completion_item.data and entry.completion_item.data.snip_id
              if snip_id then
                local ok, snip = pcall(require("luasnip").get_id_snippet, snip_id)
                if ok and snip then
                  --- @type string|string[]
                  local desc = snip.description
                  if type(desc) == "table" then desc = table.concat(desc, " ") end
                  detail = desc
                end
              end
            elseif vim_item.menu == nil or vim_item.menu == "" then
              detail = entry.completion_item.detail
            end
            if detail and detail ~= "" then
              local max = detail:find("[^\032-\126]") and 20 or 40
              if vim.fn.strchars(detail) > max then
                detail = vim.fn.strcharpart(detail, 0, max - 1) .. "…"
              end
              vim_item.menu = detail
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
          { name = "dict" },      -- English-Chinese dictionary (fallback)
        }),
      })

      -- Auto-insert "()" as snippet after confirming a Function/Method completion
      -- from LSP servers that don't provide snippet-style calls (e.g., pyright).
      -- Same approach as coc-pyright: insert `($1)$0` so cursor lands inside parens.
      -- Skips when the server already inserted parens (vtsls/clangd/lua_ls with snippets).
      local Kind = require("cmp.types").lsp.CompletionItemKind
      local paren_kinds = {
        [Kind.Function] = true,
        [Kind.Method] = true,
        [Kind.Constructor] = true,
      }
      cmp.event:on("confirm_done", function(evt)
        local item = evt.entry:get_completion_item()
        if not paren_kinds[item.kind] then return end
        -- Skip if server already inserted parens (snippet or insertText contains "(")
        local insert_text = item.insertText or (item.textEdit and item.textEdit.newText) or ""
        if insert_text:find("%(") then return end
        -- Skip if next char is already "("
        local col = vim.api.nvim_win_get_cursor(0)[2]
        local next_char = vim.api.nvim_get_current_line():sub(col + 1, col + 1)
        if next_char == "(" then return end
        luasnip.lsp_expand("($1)$0")
      end)

    end,
  },
}
