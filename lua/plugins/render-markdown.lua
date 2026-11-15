-- In-buffer markdown rendering (MeanderingProgrammer/render-markdown.nvim)
--
-- Renders markdown inside the current buffer via treesitter + extmark conceal:
-- headings get colored backgrounds/borders, code blocks get backgrounds with a
-- language label, tables are drawn with box-drawing characters, list bullets
-- and checkboxes are replaced.
--
-- Dependencies:
--   Requires treesitter parsers markdown + markdown_inline. Bundled with
--   Neovim >= 0.11 (/opt/nvim/lib/nvim/parser/), so nvim-treesitter (removed
--   from this config) is NOT needed.
--
-- No nerd font in this environment (see nvim-tree.lua). v8 removed the global
-- `icons = { enabled = false }` switch, so defaults using nerd font glyphs
-- (private use area) are overridden with plain text below:
--   heading.icons  -> keep original hash marks ('# ', '## ', ...), colored per
--                     level; trailing spaces needed (raw gap is concealed)
--   heading.sign   -> disabled ('󰫎 ' in sign column)
--   checkbox       -> U+2610/U+2611 ballot boxes
--   callout        -> same wording as defaults, nerd prefix stripped, padded to
--                     raw tag width (see NOTE in config below)
-- Components that only use plain Unicode by default (bullet '●', table borders,
-- quote '│', code '█▄▀') are left untouched.
--
-- Behavior notes:
--   - The raw text is never modified; rendering uses conceal + extmarks.
--   - anti-conceal (cursor line reveals raw source) is DISABLED in normal mode
--     (anti_conceal.disabled_modes), so decorations stay put while navigating.
--     It still applies in visual mode, where the cursor line shows raw source.
--   - insert mode shows raw source everywhere; decorations re-render on
--     leaving insert (default render_modes), keeping vim-table-mode usable.
--   - html/latex/yaml support disabled: parsers are not installed (would only
--     produce checkhealth warnings; latex rendering needs image converters too).
--
-- Commands:
--   :RenderMarkdownToggle - toggle rendering in current buffer
--   :RenderMarkdownDebug  - show debug info (config, parsers, log)
--   :checkhealth render-markdown - verify parsers and environment

return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown" },
    -- Install latest stable tag
    version = "*",
    config = function()
      -- Same wording as the plugin defaults (settings.lua), nerd prefix stripped.
      -- NOTE: v8 renders callouts via overlay virt_text without concealing
      -- (quote.lua: conceal only applies when the callout has a title). The
      -- defaults stay wide enough because their nerd icon is double-width;
      -- plain-text wording is narrower and leaks the tail of '[!TAG]' from
      -- under the overlay (e.g. 'WarningG'). Every raw tag is '[!' .. tag .. ']',
      -- so padding rendered with exactly 3 trailing spaces (do NOT strip them)
      -- makes the overlay cover the whole tag.
      local callout = {
        note      = { raw = "[!NOTE]",      rendered = "Note   ",      highlight = "RenderMarkdownInfo" },
        tip       = { raw = "[!TIP]",       rendered = "Tip   ",       highlight = "RenderMarkdownSuccess" },
        important = { raw = "[!IMPORTANT]", rendered = "Important   ", highlight = "RenderMarkdownHint" },
        warning   = { raw = "[!WARNING]",   rendered = "Warning   ",   highlight = "RenderMarkdownWarn" },
        caution   = { raw = "[!CAUTION]",   rendered = "Caution   ",   highlight = "RenderMarkdownError" },
        abstract  = { raw = "[!ABSTRACT]",  rendered = "Abstract   ",  highlight = "RenderMarkdownInfo" },
        summary   = { raw = "[!SUMMARY]",   rendered = "Summary   ",   highlight = "RenderMarkdownInfo" },
        tldr      = { raw = "[!TLDR]",      rendered = "Tldr   ",      highlight = "RenderMarkdownInfo" },
        info      = { raw = "[!INFO]",      rendered = "Info   ",      highlight = "RenderMarkdownInfo" },
        todo      = { raw = "[!TODO]",      rendered = "Todo   ",      highlight = "RenderMarkdownInfo" },
        hint      = { raw = "[!HINT]",      rendered = "Hint   ",      highlight = "RenderMarkdownSuccess" },
        success   = { raw = "[!SUCCESS]",   rendered = "Success   ",   highlight = "RenderMarkdownSuccess" },
        check     = { raw = "[!CHECK]",     rendered = "Check   ",     highlight = "RenderMarkdownSuccess" },
        done      = { raw = "[!DONE]",      rendered = "Done   ",      highlight = "RenderMarkdownSuccess" },
        question  = { raw = "[!QUESTION]",  rendered = "Question   ",  highlight = "RenderMarkdownWarn" },
        help      = { raw = "[!HELP]",      rendered = "Help   ",      highlight = "RenderMarkdownWarn" },
        faq       = { raw = "[!FAQ]",       rendered = "Faq   ",       highlight = "RenderMarkdownWarn" },
        attention = { raw = "[!ATTENTION]", rendered = "Attention   ", highlight = "RenderMarkdownWarn" },
        failure   = { raw = "[!FAILURE]",   rendered = "Failure   ",   highlight = "RenderMarkdownError" },
        fail      = { raw = "[!FAIL]",      rendered = "Fail   ",      highlight = "RenderMarkdownError" },
        missing   = { raw = "[!MISSING]",   rendered = "Missing   ",   highlight = "RenderMarkdownError" },
        danger    = { raw = "[!DANGER]",    rendered = "Danger   ",    highlight = "RenderMarkdownError" },
        error     = { raw = "[!ERROR]",     rendered = "Error   ",     highlight = "RenderMarkdownError" },
        bug       = { raw = "[!BUG]",       rendered = "Bug   ",       highlight = "RenderMarkdownError" },
        example   = { raw = "[!EXAMPLE]",   rendered = "Example   ",   highlight = "RenderMarkdownHint" },
        quote     = { raw = "[!QUOTE]",     rendered = "Quote   ",     highlight = "RenderMarkdownQuote" },
        cite      = { raw = "[!CITE]",      rendered = "Cite   ",      highlight = "RenderMarkdownQuote" },
      }

      require("render-markdown").setup({
        -- Cursor line keeps its rendered look in normal mode; anti-conceal
        -- (which reveals raw source on the cursor line only) still applies in
        -- visual mode. Insert mode shows raw text everywhere regardless (not
        -- in render_modes).
        anti_conceal = { disabled_modes = { "n" } },

        heading = {
          -- Disable sign column marker: default '󰫎 ' is a nerd font glyph
          sign = false,
          -- Keep the original hash marks: zero-width offset (icon == raw width),
          -- level info stays visible, and foregrounds (RenderMarkdownH1..H6)
          -- still color them per level. Common no-nerd-font fallback.
          icons = { "# ", "## ", "### ", "#### ", "##### ", "###### " },
        },

        checkbox = {
          -- Defaults '󰄱 '/'󰱒 ' are nerd font glyphs; ballot boxes render in
          -- any font. Trailing space keeps a gap before the item text.
          unchecked = { icon = "☐ " }, -- replaces '[ ]'
          checked = { icon = "☑ " },   -- replaces '[x]'
        },

        -- Plain-text callout labels; why they are space-padded is documented
        -- in the NOTE above the table definition
        callout = callout,

        -- Inline HTML rendering (comment concealing, per-tag icons).
        -- Disabled: html treesitter parser is not installed.
        html = { enabled = false },

        -- Latex formula rendering ($...$ to unicode via utftex/latex2text).
        -- Disabled: latex parser AND the converter binaries are missing.
        latex = { enabled = false },

        -- Frontmatter rendering (key/value blocks between '---' lines).
        -- Disabled: yaml treesitter parser is not installed.
        yaml = { enabled = false },
      })
    end,
  },
}
