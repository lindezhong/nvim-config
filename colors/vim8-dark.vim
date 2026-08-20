" colors_name must match the filename, otherwise some vim versions cannot find the scheme
" Generated from `:hi` output in a clean vim (no vimrc, no plugins):
" 1. Open vim, run `:hi` and copy all output
" 2. Remove `xxx` placeholders: `:%s/xxx//g`
" 3. Prepend `hi` to each line: `:%s/\n/\rhi /g` (manually fix the first line)
" 4. Convert cleared groups, e.g. `hi Table cleared`
"   4.1 To remove cleared: `:%s/hi\s\(\S\+\)\s\+cleared.*\n//g`
"   4.2 To keep cleared: `:%s/hi\s\(\S\+\)\s\+cleared.*\n/hi clear \1\r/g`
" 5. Convert links, e.g. `hi shHereDoc16 links to shRedir` → `hi link shHereDoc16 shRedir`
"   Regex: `:%s/hi\s\(\S\+\)\s\+links\s\+to\s\+\(\S\+\)\n/hi link \1 \2\r/g`

" Colorscheme must be loaded before any other highlight settings in vimrc,
" otherwise `hi clear` below will wipe them out
hi clear
set background=dark
" Vim8 default dark color scheme
" Explicitly set colors_name so all vim versions can find it by name
let g:colors_name = "vim8-dark"
hi SpecialKey      term=bold ctermfg=4 guifg=Blue
hi link EndOfBuffer NonText
hi NonText         term=bold ctermfg=12 gui=bold guifg=Blue
hi Directory       term=bold ctermfg=4 guifg=Blue
hi ErrorMsg        term=standout ctermfg=15 ctermbg=1 guifg=White guibg=Red
hi IncSearch       term=reverse cterm=reverse gui=reverse
hi Search          term=reverse ctermbg=11 guibg=Yellow
hi MoreMsg         term=bold ctermfg=2 gui=bold guifg=SeaGreen
hi ModeMsg         term=bold cterm=bold gui=bold
hi LineNr          term=underline ctermfg=130 guifg=Brown
hi clear LineNrAbove
hi clear LineNrBelow
hi CursorLineNr    term=bold cterm=underline ctermfg=130 gui=bold guifg=Brown
hi link CursorLineSign SignColumn
hi link CursorLineFold FoldColumn
hi Question        term=standout ctermfg=2 gui=bold guifg=SeaGreen
hi StatusLine      term=bold,reverse cterm=bold,reverse gui=bold,reverse
hi StatusLineNC    term=reverse cterm=reverse gui=reverse
hi VertSplit       term=reverse cterm=reverse gui=reverse
hi Title           term=bold ctermfg=5 gui=bold guifg=Magenta
hi Visual          term=reverse ctermbg=7 guibg=LightGrey
hi VisualNOS       term=bold,underline cterm=bold,underline gui=bold,underline
hi WarningMsg      term=standout ctermfg=1 guifg=Red
hi WildMenu        term=standout ctermfg=0 ctermbg=11 guifg=Black guibg=Yellow
hi Folded          term=standout ctermfg=4 ctermbg=248 guifg=DarkBlue guibg=LightGrey
hi FoldColumn      term=standout ctermfg=4 ctermbg=248 guifg=DarkBlue guibg=Grey
hi DiffAdd         term=bold ctermbg=81 guibg=LightBlue
hi DiffChange      term=bold ctermbg=225 guibg=LightMagenta
hi DiffDelete      term=bold ctermfg=12 ctermbg=159 gui=bold guifg=Blue guibg=LightCyan
hi DiffText        term=reverse cterm=bold ctermbg=9 gui=bold guibg=Red
hi SignColumn      term=standout ctermfg=4 ctermbg=248 guifg=DarkBlue guibg=Grey
hi Conceal         ctermfg=7 ctermbg=242 guifg=LightGrey guibg=DarkGrey
hi SpellBad        term=reverse ctermbg=224 gui=undercurl guisp=Red
hi SpellCap        term=reverse ctermbg=81 gui=undercurl guisp=Blue
hi SpellRare       term=reverse ctermbg=225 gui=undercurl guisp=Magenta
hi SpellLocal      term=underline ctermbg=14 gui=undercurl guisp=DarkCyan
hi Pmenu           ctermfg=0 ctermbg=225 guibg=LightMagenta
hi PmenuSel        ctermfg=0 ctermbg=7 guibg=Grey
hi PmenuSbar       ctermbg=248 guibg=Grey
hi PmenuThumb      ctermbg=0 guibg=Black
hi TabLine         term=underline cterm=underline ctermfg=0 ctermbg=7 gui=underline guibg=LightGrey
hi TabLineSel      term=bold cterm=bold gui=bold
hi TabLineFill     term=reverse cterm=reverse gui=reverse
hi CursorColumn    term=reverse ctermbg=7 guibg=Grey90
hi CursorLine      term=underline cterm=underline guibg=Grey90
hi ColorColumn     term=reverse ctermbg=224 guibg=LightRed
hi link QuickFixLine Search
hi StatusLineTerm  term=bold,reverse cterm=bold ctermfg=15 ctermbg=2 gui=bold guifg=bg guibg=DarkGreen
hi StatusLineTermNC  term=reverse ctermfg=15 ctermbg=2 guifg=bg guibg=DarkGreen
hi Cursor          guifg=bg guibg=fg
hi lCursor         guifg=bg guibg=fg
hi clear Normal
hi MatchParen      term=reverse ctermbg=14 guibg=Cyan
hi ToolbarLine     term=underline ctermbg=7 guibg=LightGrey
hi ToolbarButton   cterm=bold ctermfg=15 ctermbg=242 gui=bold guifg=White guibg=Grey40
hi Comment         term=bold ctermfg=4 guifg=Blue
hi Constant        term=underline ctermfg=1 guifg=Magenta
hi Special         term=bold ctermfg=5 guifg=#6a5acd
hi Identifier      term=underline ctermfg=6 guifg=DarkCyan
hi Statement       term=bold ctermfg=130 gui=bold guifg=Brown
hi PreProc         term=underline ctermfg=5 guifg=#6a0dad
hi Type            term=underline ctermfg=2 gui=bold guifg=SeaGreen
hi Underlined      term=underline cterm=underline ctermfg=5 gui=underline guifg=SlateBlue
hi Ignore          ctermfg=15 guifg=bg
hi Error           term=reverse ctermfg=15 ctermbg=9 guifg=White guibg=Red
hi Todo            term=standout ctermfg=0 ctermbg=11 guifg=Blue guibg=Yellow
hi! link String Constant
hi! link Character Constant
hi! link Number Constant
hi! link Boolean Constant
hi! link Float Number
hi! link Function Identifier
hi! link Conditional Statement
hi! link Repeat Statement
hi! link Label Statement
hi! link Operator Statement
hi! link Keyword Statement
hi! link Exception Statement
hi! link Include PreProc
hi! link Define PreProc
hi! link Macro PreProc
hi! link PreCondit PreProc
hi! link StorageClass Type
hi! link Structure Type
hi! link Typedef Type
hi! link Tag Special
hi! link SpecialChar Special
hi! link Delimiter Special
hi! link SpecialComment Special
hi! link Debug Special

" ----- Custom overrides (dark background adjustments, not from vim8 defaults) -----
" Editor background
hi Normal            ctermbg=Black
" Visual selection: black foreground for readability on highlight
hi Visual            ctermfg=Black
" Diff colors for vimdiff / git diff view
hi DiffChange        ctermfg=Black ctermbg=Blue
hi DiffText          ctermfg=Black ctermbg=Red
hi DiffAdd           ctermfg=Black ctermbg=Blue
hi DiffDelete        ctermfg=Black ctermbg=Blue
" Window separator between splits
hi WinSeparator      cterm=reverse
" Diagnostic signs: colored text on black background to match Normal
hi DiagnosticSignError ctermfg=Red ctermbg=Black
hi DiagnosticSignWarn  ctermfg=Yellow ctermbg=Black
hi DiagnosticSignInfo  ctermfg=Blue ctermbg=Black
hi DiagnosticSignHint  ctermfg=Cyan ctermbg=Black
" Sign column background (match Normal black background)
hi SignColumn        ctermbg=Black
" Match parentheses/brackets highlight: dark grey background
hi MatchParen        guibg=#4e4e4e guifg=NONE gui=NONE ctermbg=239 ctermfg=NONE cterm=NONE

" ----- Treesitter highlight groups (override nvim defaults to match vim colors) -----
hi link @variable        NONE
hi link @variable.member NONE
hi link @variable.builtin Type
hi link @constant        Constant
hi link @constant.builtin Constant
hi link @string          String
hi link @string.escape   SpecialChar
hi link @character       Character
hi link @number          Number
hi link @boolean         Boolean
hi link @type            Type
hi link @type.builtin    Type
hi link @type.qualifier  StorageClass
hi link @function        Function
hi link @function.call   Function
hi link @function.method.call NONE
hi link @keyword         Statement
hi link @keyword.conditional Statement
hi link @keyword.function Statement
hi link @keyword.operator Statement
hi link @keyword.return  Statement
hi link @keyword.import  PreProc
hi link @operator        NONE
hi link @punctuation.bracket NONE
hi link @punctuation.delimiter NONE
hi link @comment         Comment
hi link @tag             Tag
hi link @tag.attribute   Identifier
hi link @tag.delimiter   Delimiter
