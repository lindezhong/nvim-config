-- Fuzzy finder
--
-- Provides file search, buffer line search, and live grep with configurable
-- ignore patterns. Dependency/cache directories (node_modules, venv, etc.)
-- are excluded by default but can be included on-the-fly with <C-a>.
--
-- Key mappings:
--   <C-p>      file search (includes hidden + ignored files)
--   <C-f>      current buffer line search
--   <Esc><C-p> live grep (rg, includes ignored files)
--
-- Inside Telescope (press <Esc> for normal mode):
--   <CR>       open file
--   <C-x>      open in horizontal split
--   <C-v>      open in vertical split
--   <C-t>      open in new tab
--   <C-q>      send results to quickfix list
--   j/k        navigate results
--   <C-u>/<C-d> scroll preview
--   <C-a>      include dependency/cache dirs in search (node_modules, venv, etc.)
--   i          back to insert mode (filter)
--
-- External dependencies:
--   ripgrep (required for live grep): sudo apt install ripgrep

return {
  {
    "nvim-telescope/telescope.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim", -- required utility library for telescope
    },
    config = function()
      local telescope = require("telescope")
      local builtin = require("telescope.builtin")
      local actions = require("telescope.actions")

      -- Lua patterns that are always excluded from search results.
      -- Covers VCS directories, IDE project dirs, and compiled artifacts.
      --- @type string[]
      local ignore_always = {
        -- VCS/IDE directories
        "%.git/", "%.github/", "%.vim/", "%.hg/", "%.svn/",
        "%.idea/", "%.vscode/",
        -- Compiled/binary file extensions
        "%.o$", "%.a$", "%.d$", "%.i$", "%.s$", "%.bc$", "%.so$", "%.pyc$", "%.swp$", "%.class$",
      }

      -- Lua patterns excluded by default but searchable after pressing <C-a>.
      -- Typically large dependency or cache directories.
      --- @type string[]
      local ignore_toggleable = {
        "node_modules/",  -- JavaScript/TypeScript dependencies
        "__pycache__/",   -- Python bytecode cache
        "%.venv/",        -- Python virtual environment (dotfile variant)
        "venv/",          -- Python virtual environment
      }

      -- Combined pattern list used as the default filter for find_files.
      --- @type string[]
      local ignore_default = vim.list_extend(vim.deepcopy(ignore_always), ignore_toggleable)

      -- Build ripgrep exclude arguments from a pattern list.
      -- Only directory patterns (ending with "/") are converted to rg globs;
      -- file extension patterns (e.g. %.o$) are not valid rg globs and are
      -- instead filtered by Telescope's file_ignore_patterns at the result level.
      --- @param patterns string[] Lua pattern list (from ignore_always or ignore_default)
      --- @return string[] args ripgrep CLI arguments (--hidden, --no-ignore, -g exclusions)
      local function rg_dir_args(patterns)
        local args = { "--hidden", "--no-ignore" }
        for _, p in ipairs(patterns) do
          -- Only convert directory patterns (those ending with "/")
          if p:sub(-1) == "/" then
            -- Strip Lua pattern escape character "%" to get a plain glob
            table.insert(args, "-g")
            table.insert(args, "!" .. p:gsub("%%", ""))
          end
        end
        return args
      end

      -- Pre-computed rg argument lists for live_grep.
      --- @type string[]
      local rg_args_default = rg_dir_args(ignore_default)  -- excludes toggleable dirs
      --- @type string[]
      local rg_args_relaxed = rg_dir_args(ignore_always)   -- includes toggleable dirs

      -- Close the current picker and reopen with relaxed ignore patterns.
      -- Preserves the user's current query text via default_text.
      --- @param prompt_bufnr number Buffer number of the current Telescope prompt
      --- @param picker_fn function Telescope picker to reopen (e.g. builtin.find_files)
      --- @param extra_opts? table Additional options to pass to the picker
      local function reopen_relaxed(prompt_bufnr, picker_fn, extra_opts)
        -- Close the current picker window
        actions.close(prompt_bufnr)
        -- Capture the current query text before the prompt buffer is destroyed
        local text = require("telescope.actions.state").get_current_line()
        -- Merge default_text with any extra options (e.g. file_ignore_patterns override)
        local opts = vim.tbl_extend("force", { default_text = text }, extra_opts or {})
        -- Reopen the picker with the new options
        picker_fn(opts)
      end

      telescope.setup({
        defaults = {
          -- Horizontal layout: prompt + results on left, preview on right
          layout_strategy = "horizontal",
          -- Ascending sort so results fill top-down (no blank gap below prompt)
          sorting_strategy = "ascending",
          layout_config = {
            -- Prompt at top, results below it
            prompt_position = "top",
            horizontal = {
              -- Preview pane takes 60% width, results take 40%
              preview_width = 0.6,
            },
            -- Near-fullscreen floating window
            width = 0.99,
            height = 0.99,
          },
          -- Dynamically shorten paths: show filename only when unique,
          -- expand parent dirs progressively when names collide
          path_display = { "smart" },
          -- Only ignore_always here (not ignore_default); <C-p> keymap passes
          -- ignore_default explicitly because vim.tbl_deep_extend merges arrays
          -- by index — a shorter override list cannot remove trailing entries.
          file_ignore_patterns = ignore_always,
        },
        pickers = {
          find_files = {
            -- Include dotfiles (hidden files)
            hidden = true,
            -- Include files excluded by .gitignore
            no_ignore = true,
            -- Custom entry maker: fuzzy-match on filename only (not full path).
            -- IIFE creates a closure over gen at config time; gen_from_file is
            -- stateless so the closure is safe across cwd changes.
            entry_maker = (function()
              --- @type function
              local gen = require("telescope.make_entry").gen_from_file({})
              --- @param line string Raw file path from the file finder
              --- @return table|nil entry Telescope entry with filename-only ordinal
              return function(line)
                local entry = gen(line)
                if entry then
                  -- Set ordinal to filename only so fuzzy matching ignores directory path
                  entry.ordinal = vim.fn.fnamemodify(line, ":t")
                end
                return entry
              end
            end)(),
            mappings = {
              -- <C-a> reopens find_files with only ignore_always (includes toggleable dirs)
              i = {
                ["<C-a>"] = function(bufnr) reopen_relaxed(bufnr, builtin.find_files, { file_ignore_patterns = ignore_always }) end,
              },
              n = {
                ["<C-a>"] = function(bufnr) reopen_relaxed(bufnr, builtin.find_files, { file_ignore_patterns = ignore_always }) end,
              },
            },
          },
          live_grep = {
            -- Use function (not table) to avoid vim.tbl_deep_extend array merge
            -- issue: when <C-a> overrides with a shorter args list, a table value
            -- would retain trailing entries from the picker default.
            additional_args = function() return rg_args_default end,
            mappings = {
              -- <C-a> reopens live_grep with rg_args_relaxed (includes toggleable dirs)
              i = {
                ["<C-a>"] = function(bufnr) reopen_relaxed(bufnr, builtin.live_grep, { additional_args = function() return rg_args_relaxed end }) end,
              },
              n = {
                ["<C-a>"] = function(bufnr) reopen_relaxed(bufnr, builtin.live_grep, { additional_args = function() return rg_args_relaxed end }) end,
              },
            },
          },
        },
      })

      -- File search (normal + insert mode)
      -- Passes ignore_default explicitly to include toggleable exclusions;
      -- see comment at defaults.file_ignore_patterns for the reason.
      vim.keymap.set("n", "<C-p>", function() builtin.find_files({ file_ignore_patterns = ignore_default }) end, { silent = true })
      vim.keymap.set("i", "<C-p>", function() vim.cmd("stopinsert"); builtin.find_files({ file_ignore_patterns = ignore_default }) end, { silent = true })

      -- Current buffer line search (normal + insert mode)
      vim.keymap.set("n", "<C-f>", builtin.current_buffer_fuzzy_find, { silent = true })
      vim.keymap.set("i", "<C-f>", function() vim.cmd("stopinsert"); builtin.current_buffer_fuzzy_find() end, { silent = true })

      -- Live grep (normal + insert mode)
      vim.keymap.set("n", "<Esc><C-p>", builtin.live_grep, { silent = true })
      vim.keymap.set("i", "<Esc><C-p>", function() vim.cmd("stopinsert"); builtin.live_grep() end, { silent = true })

    end,
  },
}
