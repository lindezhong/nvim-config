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
--   - Wide table rows fold to fit the window. A Marks:replace override (in
--     config below) draws fold line 1 as overlay INSIDE the raw row, so the
--     cursor resting on a folded row keeps the aligned grid instead of
--     flipping to raw source (upstream behavior, hard-coded in core/ui.lua).
--     If the folded row is the LAST line of the buffer the grid is drawn
--     above it and the row itself becomes a blank line (see EXCEPTION in
--     the override comment).
--   - insert mode shows raw source everywhere; decorations re-render on
--     leaving insert (default render_modes), keeping vim-table-mode usable.
--   - scratch popups (buftype=nofile) skip rendering entirely; fences there
--     are concealed by the builtin treesitter query in windows with
--     conceallevel >= 2 (as LSP hover floats set), kept alive by the query
--     rewrite in the config below - the plugin default would disable it
--     globally, exposing raw fences in LSP hover floats.
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

        -- Plugin default ('rendered = ""') reveals concealed text under the
        -- cursor in every mode, which flips short (non-folded) table rows and
        -- inline '**'/'`' markers back to raw source on the cursor line.
        -- 'n' keeps them rendered in normal mode; visual mode still reveals.
        -- The wide-table override below only covers folded rows, not these.
        win_options = {
          concealcursor = { rendered = "n" },
        },

        -- Skip rendering in scratch popups (buftype=nofile)
        overrides = {
          buftype = {
            nofile = { enabled = false },
          },
        },

        heading = {
          -- Empty list disables the full-line background highlight
          -- (default RenderMarkdownH1Bg..H6Bg); border defaults to false,
          -- so nothing replaces it. Hash-mark foregrounds stay.
          backgrounds = {},
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

      -- Rewrite the builtin markdown highlights query with the line-level
      -- conceal_lines directives removed, keeping the char-level
      -- 'conceal ""' on the same patterns. Rationale: on first attach the
      -- plugin looks up conceal_lines directives in this query and disables
      -- the whole patterns globally - including for markdown buffers where
      -- it does not render (the nofile override above), which exposes raw
      -- fences in LSP hover floats. With the directives gone the disable
      -- step finds nothing to do, so concealing survives everywhere, while
      -- rendered buffers are unaffected (the plugin conceals fences itself).
      -- Run at setup time, before any markdown buffer attaches.
      -- HACK: matches the directive text of nvim 0.11's bundled query and
      -- the plugin's directive lookup (core/ts.lua). Additional override
      -- files are read and stripped the same way; if a directive's text
      -- ever changes the verification below errors when the plugin loads
      -- instead of silently re-breaking hover floats. Quick revert: delete
      -- this whole block.
      local parts = {}
      for _, file in ipairs(vim.treesitter.query.get_files("markdown", "highlights")) do
        local handle = assert(io.open(file, "r"))
        parts[#parts + 1] = handle:read("*a")
        handle:close()
      end
      -- query.get concatenates all files the same way (read_query_files),
      -- so the rewrite must too; otherwise patterns from other files survive.
      local source = table.concat(parts, "")
      vim.treesitter.query.set(
        "markdown",
        "highlights",
        (source:gsub('%(#set! conceal_lines ""%)', ""))
      )
      -- set() clears the query cache; get() re-derives from the explicit
      -- query (no '; inherits' modelines -> runtime files are not prepended)
      -- and parses it here, so syntax errors also surface when the plugin
      -- loads rather than when the first buffer renders.
      if vim.treesitter.query.get("markdown", "highlights").has_conceal_line then
        error("render-markdown.lua: markdown highlights query still has conceal_lines")
      end

      -- Folded table rows without the cursor-row flip. Upstream folds a row
      -- wider than the window via extmark 'conceal_lines' (zero screen
      -- height) + virtual lines; when the cursor lands on such a row the
      -- extmark is dropped wholesale (core/ui.lua hard-codes: "virtual row ->
      -- no editable screen cells -> must hide"), revealing raw source and
      -- breaking grid alignment. Instead the first grid line is drawn as an
      -- 'overlay' virt_text inside the raw row itself (overlay survives on
      -- the cursor line, same as the pipe borders; grid lines are built to
      -- the window budget, so the overlay spans every visible cell) and the
      -- remaining lines attach as virt_lines below. No zero-height row
      -- exists, so the cursor always has screen cells: no flip, and j/down
      -- move normally. Lives in this file, so plugin updates cannot lose it.
      --
      -- EXCEPTION for a folded row on the LAST buffer line: Neovim never
      -- reserves rows below the last line (scrolloff is relaxed there), so
      -- below-attached virt_lines clip once the window is scrolled to the
      -- bottom. Draw the whole grid (all lines, bottom border included)
      -- ABOVE the row instead and blank the row itself with an overlay of
      -- spaces; the table ends in one blank screen row but always displays
      -- in full. Only applies when there IS a continuation: a single-line
      -- fold still draws onto the row, where it is always visible.
      --
      -- HACK: this overrides a plugin-internal method (lib.marks.replace,
      -- written against v8.14.0) and may break after plugin updates - either
      -- silently (the cursor flip returns) or with render errors on folded
      -- tables; in both cases delete or re-adapt this block.
      -- Quick revert: delete this whole block (both require() lines and the
      -- marks:replace function below) - stock upstream behavior returns.
      local marks = require("render-markdown.lib.marks")
      local str = require("render-markdown.lib.str")
      function marks:replace(config, node, lines)
        local last_line = vim.api.nvim_buf_line_count(self.context.buf) - 1
        local is_last_line = node.end_row >= last_line
        if is_last_line and #lines > 1 then
          self:insert(config, {
            conceal = true,
            start_row = node.start_row,
            start_col = node.start_col,
            opts = {
              end_row = node.end_row,
              end_col = node.end_col,
              virt_text = { { (" "):rep(str.line_width(lines[1])) } },
              virt_text_pos = "overlay",
            },
          })
          self:insert(config, {
            conceal = true,
            start_row = node.start_row,
            start_col = 0,
            opts = {
              virt_lines = lines,
              virt_lines_above = true,
            },
          })
          return
        end
        self:insert(config, {
          conceal = true,
          start_row = node.start_row,
          start_col = node.start_col,
          opts = {
            end_row = node.end_row,
            end_col = node.end_col,
            virt_text = lines[1],
            virt_text_pos = "overlay",
          },
        })
        if #lines > 1 then
          self:insert(config, {
            conceal = true,
            start_row = node.start_row,
            start_col = 0,
            opts = {
              virt_lines = vim.list_slice(lines, 2),
              virt_lines_above = false,
            },
          })
        end
      end
    end,
  },
}
