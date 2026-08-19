-- Table mode (dhruvasagar/vim-table-mode)
--
-- Automatic table formatting, alignment, and formula evaluation for
-- Markdown/text tables.
--
-- Table data format: | col1 | col2 | (spaces around | are required)
--
-- Commands:
--   :TableModeEnable       enable table mode (auto-align on |)
--   :TableModeDisable      disable table mode
--   :TableModeToggle       toggle table mode
--   :TableEvalFormulaLine  evaluate formulas defined in comment line below table
--   :TableAddFormula        add formula for cell under cursor
--
-- Quick triggers (insert mode):
--   ||   auto-generate separator line (when at start of line with existing table)
--   __   disable table mode
--
-- ===========================================================================
-- # Table Formula Usage
--
-- ## Formula Expression Format
--
-- The expression format is `$target = formula`
-- The target can take two forms:
--   1. `$c` - matches column number c. The formula is evaluated for every cell
--      in that column. Negative indices are relative to the last column
--      (e.g. -1 = last column).
--   2. `$r,c` - matches a specific cell at row r, column c. The formula is
--      evaluated once and the result is placed in that cell. Negative values
--      reference relative to table size (e.g. -1 = last row/column).
--   Note: Row and column indices start from 1.
--
-- The `formula` is a simple math expression. Cell references in the formula
-- use the same format as the target. You can use any native Vim function
-- (see `:h function-list`) and custom functions.
--
-- The plugin provides special functions that accept a range as input.
-- Range formats:
--   1. `r1:r2` - cells from row r1 to row r2 in the current column.
--      If r2 is negative, it means r2 rows above the target cell.
--   2. `r1,c1:r2,c2` - cells from (r1,c1) to (r2,c2) in the table.
--
-- ## How to Write Formulas
--
-- Formulas are written in a comment line below the table, starting with `tmf:`
-- Multiple formulas are separated by `;`
--
-- Per-filetype syntax:
--   Markdown: <!-- tmf: $1,11=$1 * $1 -->
--             <!-- tmf: $1,11=$1 * $1;$2,11=$1 * $1 -->
--   Shell:    # tmf: $1,11=$1 * $1
--             # tmf: $1,11=$1 * $1;$2,11=$1 * $1
--   Plain text: (leading space required, must be on its own line)
--              tmf: $1,11=$1 * $1
--              tmf: $1,11=$1 * $1;$2,11=$1 * $1
--
-- ## Official Examples
--
--   1. `$2 = $1 * $1`
--   2. `$2 = pow($1, 5)`  (note: space between $1 and 5 required,
--      otherwise it's treated as cell $1,5)
--   3. `$2 = $1 / $1,3`
--   4. `$1,2 = $1,1 * $1,1`
--   5. `$5,1 = Sum(1:-1)`
--   6. `$5,1 = float2nr(Sum(1:-1))`
--   7. `$5,3 = Sum(1,2:5,2)`
--   8. `$5,3 = Sum(1,2:5,2)/$5,1`
--   9. `$5,3 = Average(1,2:5,2)/$5,1`
--
-- ## Common Practical Examples
--
--   1. `$r,c=Sum(1:-1)`        sum column c from row 1 to r-1 into (r,c);
--                               r=-1 means last row
--   2. `$r,c=Average(1:-1)`    average column c from row 1 to r-1 into (r,c)
--   3. `$c3=$c1+$c2`           col3 = col1 + col2 (also works with - * /)
--   4. `$c3=str2float($c1)/$c2`  col3 = col1 / col2; without str2float(),
--                               integer division truncates
--   5. `$c3=$c1$c2`            string concatenation (col1 appended to col2)
--   6. `$r,n=cond ? val_true : val_false`  ternary operator supported
--   7. Custom functions can be used in formulas
--   8. `$-1,-1=ForColumn('SumC(1:-1)', line, row, colm)`
--                               last row: each column = sum of that column
--   9. `$r3,-1=ForColumn('#r2 + #r1', line, row, colm)`
--                               row 3 = row 2 + row 1 (across all columns)
--
-- ## Built-in Formula Functions
--
-- Source: vim-table-mode/autoload/tablemode/spreadsheet/formula.vim
-- All functions accept the same range format as input:
--   1. `r1:r2` - rows r1 to r2 in current column (negative r2 = relative)
--   2. `r1,c1:r2,c2` - cell range from (r1,c1) to (r2,c2)
--
--   Min(range)        minimum value in range
--   Max(range)        maximum value in range
--   CountE(range)     count of empty cells
--   CountNE(range)    count of non-empty cells
--   PercentE(range)   percentage of empty cells
--   PercentNE(range)  percentage of non-empty cells
--   Sum(range)        sum of values in range
--   Average(range)    average value (empty cells count as 0)
--                     Average = Sum / TotalCells
--   AverageNE(range)  average value (empty cells excluded)
--                     AverageNE = Sum / CountNE
--
-- ## Custom Functions (defined in this file)
--
--   AutoSumRow(line, row, colm)
--     Sum all cells in row into $target.
--     Usage: `$r,-1=AutoSumRow(line, row, colm)` sum row r into last column
--            `$-1=AutoSumRow(line, row, colm)` sum each row into last column
--
--   AutoAverageRow(line, row, colm)
--     Average all cells in row (empty=0) into $target.
--     Usage: `$r,-1=AutoAverageRow(line, row, colm)`
--            `$-1=AutoAverageRow(line, row, colm)`
--
--   AutoAverageNERow(line, row, colm)
--     Average all cells in row (empty cells excluded) into $target.
--     Usage: `$r,-1=AutoAverageNERow(line, row, colm)`
--            `$-1=AutoAverageNERow(line, row, colm)`
--
--   ForColumn('formula', line, row, colm)
--     Iterate formula from column 1 to column c (a column-wise loop).
--     Essentially the loop version of `$c=formula`.
--     The $target must use `$r,c` format to ensure correct row context.
--
--     Within the formula:
--       - Use `#r1` to reference cell (r1, current_column) during iteration
--       - Built-in functions need a `C` suffix when used inside ForColumn
--         e.g. Sum(1:-1) -> SumC(1:-1), Average(1:-1) -> AverageC(1:-1)
--         (This avoids conflicts with vim-table-mode's internal processing)
--
--     Example 1: Sum each column into last row
--       (3,1)=(1,1)+(2,1), (3,2)=(1,2)+(2,2)
--       | 1    | 2    |
--       |------|------|
--       | 11   | 12   |
--       | 21   | 22   |
--       | 32.0 | 34.0 |
--       <!-- tmf: $-1,-1=ForColumn('SumC(1:-1)', line, row, colm) -->
--
--     Example 2: Subtraction across columns
--       (3,1)=(2,1)-(1,1), (3,2)=(2,2)-(1,2)
--       | 1  | 2  |
--       |----|----|
--       | 11 | 12 |
--       | 21 | 22 |
--       | 10 | 10 |
--       <!-- tmf: $-1,-1=ForColumn('#2 - #1', line, row, colm) -->
--
-- ## Comprehensive Example
--
-- Given a custom function:
--   function! SumNumber(num1, num2)
--       return a:num1 + a:num2
--   endfunction
--
--   | 1    | 2  | 3  | 4        | 5              |
--   |------|----|----|----------|----------------|
--   | 11   | 12 | 13 | 0.916667 | 11concat12     |
--   | 21   | 22 | 23 | 0.954545 | 21concat22     |
--   | 32.0 | 34 | 0  | 0.941176 | 32.0concat34   |
--   <!-- tmf: $-1,1=Sum(1:-1); $3,2=SumNumber($1,2, $2,2); $3,3=$1,3 > 100 ? $1,3 : 0; $4=str2float($1)/$2; $5=$1 . 'concat' . $2 -->
--            ^sum             ^custom func            ^ternary                   ^division            ^string concat
--
-- ## How to Add Formulas
--
-- There are two ways to add table formulas:
--
-- ### Method 1: :TableAddFormula
--
-- Place cursor on a cell, run `:TableAddFormula`, then type the formula
-- after the `f=` prompt. The $target is automatically set to the cursor's
-- current row,column position (cannot be changed).
--
-- If a formula line already exists, the new formula is appended to it;
-- otherwise a new formula line is created.
--
-- Note: In markdown, appending may fail due to comment syntax handling.
-- Works best in plain text files.
--
-- Example (cursor at @ position):
--   Original:                      After :TableAddFormula → $1+$2:
--   | 1  | 2  | 3  |              | 1  | 2  | 3  |
--   |----|----|----|              |----|----|----|
--   | 11 | 12 | @  |              | 11 | 12 | 23 |
--   | 21 | 22 |    |              | 21 | 22 |    |
--                                  <!-- tmf: $1,3=$1+$2 -->
--
-- ### Method 2: :TableEvalFormulaLine
--
-- Manually write the formula line below the table, then run
-- `:TableEvalFormulaLine` to evaluate all formulas and refresh cell values.
-- See "How to Write Formulas" section for syntax.
--
-- Example:
--   Original + formula line:       After :TableEvalFormulaLine:
--   | 1  | 2  | 3  |              | 1  | 2  | 3  |
--   |----|----|----|              |----|----|----|
--   | 11 | 12 |    |              | 11 | 12 | 23 |
--   | 21 | 22 |    |              | 21 | 22 | 43 |
--   <!-- tmf: $3=$1+$2 -->        <!-- tmf: $3=$1+$2 -->
--
-- ## Best Practices
--
-- 1. Write formula on a blank line: `tmf: $target=formula`
-- 2. Comment out the formula line (e.g. in markdown wrap with <!-- -->)
--    For plain text files, just add a leading space
-- 3. If unsure about syntax, use `:TableAddFormula` to generate a simple
--    example first
-- 4. To check cursor position (row,column), the original vimrc used `\r`
--    (now mapped to DBUI_ToggleResultLayout; use
--    `:echo tablemode#spreadsheet#RowNr('.') . ',' . tablemode#spreadsheet#ColumnNr('.')`)
-- ===========================================================================

--- @type LazyPluginSpec[]
return {
  {
    "dhruvasagar/vim-table-mode",
    ft = { "markdown", "text" },
    cmd = { "TableModeEnable", "TableModeDisable", "TableModeToggle", "TableEvalFormulaLine", "TableAddFormula" },
    config = function()
      -- Auto-enable table mode only for ft-triggered loads (markdown, text)
      vim.api.nvim_create_autocmd("FileType", {
        pattern = { "markdown", "text" },
        callback = function()
          vim.cmd("silent! TableModeEnable")
        end,
      })
      -- Enable immediately if current buffer already matches
      local ft = vim.bo.filetype
      if ft == "markdown" or ft == "text" then
        vim.cmd("silent! TableModeEnable")
      end

      -- Abbreviation triggers for table editing (insert mode)
      -- || at start of line -> generate separator line
      -- __ at start of line -> disable table mode
      vim.cmd([[
        " s:isAtStartOfLine(mapping) -> bool
        " Check if {mapping} appears at the start of the current line (optionally
        " preceded by a comment prefix and whitespace). Used by abbreviation
        " triggers to only expand || and __ when they are the first content.
        function! s:isAtStartOfLine(mapping)
          let text_before_cursor = getline('.')[0 : col('.')-1]
          let mapping_pattern = '\V' . escape(a:mapping, '\')
          let comment_pattern = '\V' . escape(substitute(&l:commentstring, '%s.*$', '', ''), '\')
          return (text_before_cursor =~? '^' . ('\v(' . comment_pattern . '\v)?') . '\s*\v' . mapping_pattern . '\v$')
        endfunction

        inoreabbrev <expr> <bar><bar>
              \ <SID>isAtStartOfLine('\|\|') ?
              \ '<c-o>:TableModeEnable<cr><bar><space><bar><left><left>' : '<bar><bar>'
        inoreabbrev <expr> __
              \ <SID>isAtStartOfLine('__') ?
              \ '<c-o>:silent! TableModeDisable<cr>' : '__'
      ]])

      -- Custom formula functions (Vimscript required for tablemode# API compatibility)
      vim.cmd([[
        " ForColumn(expr, line, row, colm) -> string
        " Evaluate {expr} for each column from 1 to {colm}, writing results into
        " row {row}. This is the column-loop version of `$c=formula`.
        " Inside {expr}, use `#N` to reference cell (row N, current column), and
        " append `C` to built-in function names (e.g. SumC, AverageC).
        " {line}: line number of the table separator (passed by plugin)
        " {row}:  target row index (1-based)
        " {colm}: target column index (negative = relative to last column, 0 = last)
        " Returns: the final cell value at (row, colm)
        function! ForColumn(expr, line, row, colm)
            let expr = a:expr
            let line = a:line
            let row = a:row
            let colm = a:colm

            " Resolve actual column count for negative/zero colm
            let column_count = tablemode#spreadsheet#ColumnCount(line)
            if colm == 0
                let real_colm = column_count
            elseif colm < 0
                let real_colm = column_count + colm + 1
                if real_colm <= 0
                    let real_colm = 1
                endif
            else
                let real_colm = colm
            endif

            " Iterate each column: replace *C() function calls with actual
            " tablemode# API calls using current column, then evaluate
            for column in range(1, real_colm)
                let texpr = expr

                if texpr =~# 'MaxC(.*)'
                    let texpr = substitute(texpr, 'MaxC(\([^)]*\))', 'tablemode#spreadsheet#Max("\1",'.line.','.column.')', 'g')
                endif

                if texpr =~# 'MinC(.*)'
                    let texpr = substitute(texpr, 'MinC(\([^)]*\))', 'tablemode#spreadsheet#Min("\1",'.line.','.column.')', 'g')
                endif

                if texpr =~# 'CountEC(.*)'
                    let texpr = substitute(texpr, 'CountEC(\([^)]*\))', 'tablemode#spreadsheet#CountE("\1",'.line.','.column.')', 'g')
                endif

                if texpr =~# 'CountNEC(.*)'
                    let texpr = substitute(texpr, 'CountNEC(\([^)]*\))', 'tablemode#spreadsheet#CountNE("\1",'.line.','.column.')', 'g')
                endif

                if texpr =~# 'PercentEC(.*)'
                    let texpr = substitute(texpr, 'PercentEC(\([^)]*\))', 'tablemode#spreadsheet#PercentE("\1",'.line.','.column.')', 'g')
                endif

                if texpr =~# 'PercentNEC(.*)'
                    let texpr = substitute(texpr, 'PercentNEC(\([^)]*\))', 'tablemode#spreadsheet#PercentNE("\1",'.line.','.column.')', 'g')
                endif

                if texpr =~# 'SumC(.*)'
                    let texpr = substitute(texpr, 'SumC(\([^)]*\))', 'tablemode#spreadsheet#Sum("\1",'.line.','.column.')', 'g')
                endif

                if texpr =~# 'AverageC(.*)'
                    let texpr = substitute(texpr, 'AverageC(\([^)]*\))', 'tablemode#spreadsheet#Average("\1",'.line.','.column.')', 'g')
                endif

                if texpr =~# 'AverageNEC(.*)'
                    let texpr = substitute(texpr, 'AverageNEC(\([^)]*\))', 'tablemode#spreadsheet#AverageNE("\1",'.line.','.column.')', 'g')
                endif

                " Replace #N references with actual cell values at (row N, column)
                if expr =~# '\#'
                    let texpr = substitute(texpr, '\#\(\d\+\)',
                        \  '\=tablemode#spreadsheet#cell#GetCells(line, submatch(1), column)', 'g')
                endif
                " Evaluate the expression and write result into the cell
                silent! call tablemode#spreadsheet#cell#SetCell(eval(texpr), line, row, column)
            endfor
            return tablemode#spreadsheet#cell#GetCells(line, row, colm)
        endfunction

        " AutoSumRow(line, row, colm) -> number
        " Sum all cells in {row} (from col 1 to last col) into the target cell.
        " Usage: `$r,-1=AutoSumRow(line, row, colm)`
        function! AutoSumRow(line, row, colm)
            let args = a:row . ',1:' . a:row . ',-1'
            return tablemode#spreadsheet#Sum(args, a:line, a:colm)
        endfunction

        " AutoAverageRow(line, row, colm) -> number
        " Average all cells in {row}; empty cells count as 0.
        " Usage: `$r,-1=AutoAverageRow(line, row, colm)`
        function! AutoAverageRow(line, row, colm)
            let args = a:row . ',1:' . a:row . ',-1'
            return tablemode#spreadsheet#Average(args, a:line, a:colm)
        endfunction

        " AutoAverageNERow(line, row, colm) -> number
        " Average all cells in {row}; empty cells are excluded from calculation.
        " Usage: `$r,-1=AutoAverageNERow(line, row, colm)`
        function! AutoAverageNERow(line, row, colm)
            let args = a:row . ',1:' . a:row . ',-1'
            return tablemode#spreadsheet#AverageNE(args, a:line, a:colm)
        endfunction
      ]])
    end,
  },
}
