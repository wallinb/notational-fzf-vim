"============================== Utility functions =============================

" XXX: fnameescape vs. shellescape: for vim's consumption vs. the shell's
" consumption

function! s:single_quote(str)
    return "'" . a:str . "'"
endfunction

"============================= Dependencies ================================

if !executable('rg')
    echoerr '`rg` is not installed. See https://github.com/BurntSushi/ripgrep for installation instructions.'
    finish
endif

"============================== User settings ==============================


if !exists('g:nv_search_paths')

    if exists('g:nv_directories')
        echoerr '`g:nv_directories` has been renamed `g:nv_search_paths`. Please update your config files.'
    else
        echoerr '`g:nv_search_paths` is not defined.'
    endif

    finish

endif

let s:window_direction = get(g:, 'nv_window_direction', 'down')
let s:window_width = get(g:, 'nv_window_width', '40%')

let s:ext = get(g:, 'nv_default_extension', '.md')

" Valid options are ['up', 'down', 'right', 'left']. Default is 'right'. No colon for
" this command since it's first in the list.
let s:preview_direction = get(g:, 'nv_preview_direction', 'right')

let s:wrap_text = get(g:, 'nv_wrap_preview_text', 0) ? 'wrap' : ''

" Show preview unless user set it to be hidden
let s:show_preview = get(g:, 'nv_show_preview', 1) ? '' : 'hidden'

" How wide to make preview window. 72 characters is default.
let s:preview_width = exists('g:nv_preview_width') ? string(float2nr(str2float(g:nv_preview_width) / 100.0 * &columns)) : ''

" Expand all directories and escape metacharacters to avoid issues later.
let s:search_paths = map(copy(g:nv_search_paths), 'expand(v:val)')

" Separator for yanked files
let s:yank_separator = get(g:, 'nv_yank_separator', "\n")

" The `exists()` check needs to be first in case the main directory is not
" part of `g:nv_search_paths`.
if exists('g:nv_main_directory')
    let s:main_dir = g:nv_main_directory
else
    for path in s:search_paths
        if isdirectory(path)
            let s:main_dir = path
            break
        endif
    endfor

    " this awkward bit of code is to get around the lack of a for-else
    " loop in vim
    if !exists('s:main_dir')
        echomsg 'no directories found in `g:nv_search_paths`'
        finish
    endif
endif

let s:search_path_str = join(map(copy(s:search_paths), 'shellescape(v:val)'))

"=========================== Keymap ========================================

let s:create_note_key = get(g:, 'nv_create_note_key', 'ctrl-x')
let s:create_local_note_key = get(g:, 'nv_create_local_note_key', 'ctrl-l')
let s:yank_key = get(g:, 'nv_yank_key', 'ctrl-y')
let s:create_note_window = get(g:, 'nv_create_note_window', 'vertical split ')

let s:keymap = get(g:, 'nv_keymap',
            \ {'ctrl-s': 'split',
            \ 'ctrl-v': 'vertical split',
            \ 'ctrl-t': 'tabedit',
            \ })

" Use `extend` in case user overrides default keys
let s:keymap = extend(s:keymap, {
            \ s:create_note_key : s:create_note_window,
            \ s:create_local_note_key : s:create_note_window,
            \ })

" FZF expects a comma separated string.
let s:expect_keys = join(keys(s:keymap) + get(g:, 'nv_expect_keys', []), ',')

"================================ Yank string ==============================

function! s:yank_to_register(data)
  let @" = a:data
  silent! let @* = a:data
  silent! let @+ = a:data
endfunction

"================================ Short Pathnames ==========================

let s:use_short_pathnames = get(g:, 'nv_use_short_pathnames', 0)

" Python 3 is required for this to work
let s:python_executable = executable('pypy3') ? 'pypy3' : 'python3'
let s:highlight_path_expr = join([s:python_executable , '-S',expand('<sfile>:p:h:h') . '/print_lines.py' , '{2} {1} ', '2>/dev/null',])

if s:use_short_pathnames
    let s:format_path_expr = join([' | ', s:python_executable, '-S', shellescape(expand('<sfile>:p:h:h') . '/shorten_path_for_notational_fzf.py'),])
    " After piping through the Python script, our format is
    " filename:linum:shortname:linenum:contents, so we start at index 3 to
    " avoid displaying the long pathname
    " We skip index 4 to avoid showing line numbers
    let s:display_start_index = '3,5..'
else
    let s:format_path_expr = ''
    " Since we don't pipe through the python script, our data format is
    " filename:linenum:contents, so we start at 1.
    let s:display_start_index = '1..'
endif

"============================ Ignore patterns ==============================

function! s:ignore_list_to_str(pattern)
    "list -> space separated string of glob patterns.
    " Format to ignore a pattern.
    " XXX The leading space matters.
    let l:glob_fmt = ' --glob !'
    return l:glob_fmt . join(map(copy(a:pattern), 's:single_quote(v:val)'), l:glob_fmt) " prepend glob format string so the first pattern is ignored too.
endfunction

let s:nv_ignore_pattern = exists('g:nv_ignore_pattern') ? s:ignore_list_to_str(g:nv_ignore_pattern) : ''

"============================== Handler Function ===========================

function! s:handler(lines) abort
    " exit if empty
    if a:lines == [] || a:lines == ['','','']
        return
    endif
   " Expect at least 2 elements, `query` and `keypress`, which may be empty
   " strings.
   let query    = a:lines[0]
   let keypress = a:lines[1]
   " `edit` is fallback in case something goes wrong
   let cmd = get(s:keymap, keypress, 'edit')
   " Preprocess candidates here. expect lines to have fmt
   " filename:linenum:content

   " Handle creating note.
   if keypress ==? s:create_note_key
     let candidates = [fnameescape(s:main_dir  . '/' . query . s:ext)]
   elseif keypress ==? s:yank_key
     let pat = '\v(.{-}):\d+:'
     let hashes = join(filter(map(copy(a:lines[2:]), 'matchlist(v:val, pat)[1]'), 'len(v:val)'), s:yank_separator)
     return s:yank_to_register(hashes)
   else
       let filenames = a:lines[2:]
       let candidates = []
       for filename in filenames
           " Don't forget trailing space in replacement.
           let linenum = substitute(filename, '\v.{-}:(\d+):.*$', '+\1 ', '')
           let name = substitute(filename, '\v(.{-}):\d+:.*$', '\1', '')
           " fnameescape instead of shellescape because the file is consumed
           " by vim rather than the shell
           call add(candidates, linenum . fnameescape(name))
       endfor
   endif

   for candidate in candidates
       execute join([cmd, candidate])
   endfor

endfunction


function! NV_note_handler(lines) abort
   " exit if empty
   if a:lines == [] || a:lines == ['','','']
       return
   endif
   " expect at least 2 elements, query and keypress, which may be empty strings
   let query = a:lines[0]
   let keypress = a:lines[1]
   " Don't forget to add spaces for the commands
   let cmd = get(s:keymap, keypress, 'edit')
   " Preprocess candidates here. Expect lines to have format
   " `filename:linenum:content`
   
   if keypress ==? s:create_local_note_key
     let candidates = [fnameescape(g:nv_local_dir  . '/' . query . s:ext)]
   elseif keypress ==? s:create_note_key
     let candidates = [fnameescape(s:main_dir  . '/' . query . s:ext)]
   else
       let filenames = a:lines[2:]
       let l:candidates = []
       for l:filename in l:filenames
           " Don't forget trailing space in replacement.
           let linenum = substitute(filename, '\v.{-}:(\d+):.*$', '+\1 ', '')
           let name = substitute(filename, '\v(.{-}):\d+:.*$', '\1', '')
           " fnameescape instead of shellescape because the file is consumed
           " by vim rather than the shell
           call add(candidates, linenum . fnameescape(name))
       endfor
   endif

   for candidate in candidates
       execute join([cmd, candidate])
   endfor
endfunction

" If the file you're looking for is empty, then why does it even exist? It's a
" note. Just type its name. Hence we ignore lines with only space characters,
" and use the "\S" regex.

" Use a big ugly option list. The '.. ' is because fzf wants a term of the
" form 'N.. ' where N is a number.

" Use `command` in front of 'rg' to ignore aliases.
" The `' "\S" '` is so that the backslash itself doesn't require escaping.
" g:search_paths is already shell escaped, so we don't do it again
command! -nargs=* -bang NV
      \ call fzf#run(
          \ fzf#wrap({
              \ 'sink*': function(exists('*NV_note_handler') ? 'NV_note_handler' : '<sid>handler'),
              \ 'source': join([
                   \ 'command',
                   \ 'rg',
                   \ '--follow',
                   \ '--smart-case',
                   \ '--hidden',
                   \ '--line-number',
                   \ '--color never',
                   \ '--no-messages',
                   \ s:nv_ignore_pattern,
                   \ '--no-heading',
                   \ '--with-filename',
                   \ ((<q-args> is '') ?
                     \ '"\S"' :
                     \ shellescape(<q-args>)),
                   \ s:search_path_str,
                   \ s:format_path_expr,
                   \ '2>/dev/null',
                   \ ]),
              \ s:window_direction: s:window_width,
              \ 'options': join([
                               \ '--print-query',
                               \ '--ansi',
                               \ '--multi',
                               \ '--exact',
                               \ '--expect=ctrl-y',
                               \ '--inline-info',
                               \ '--delimiter=":"',
                               \ '--with-nth=' . s:display_start_index ,
                               \ '--tiebreak=' . 'length,begin' ,
                               \ '--expect=' . s:expect_keys ,
                               \ '--bind=' .  join([
                                              \ 'alt-a:select-all',
                                              \ 'alt-q:deselect-all',
                                              \ 'alt-p:toggle-preview',
                                              \ 'alt-u:page-up',
                                              \ 'alt-d:page-down',
                                              \ 'ctrl-w:backward-kill-word',
                                              \ ], ','),
                               \ '--preview=' . shellescape(s:highlight_path_expr) ,
                               \ '--preview-window=' . join(filter(copy([
                                                                   \ s:preview_direction,
                                                                   \ s:preview_width,
                                                                   \ s:wrap_text,
                                                                   \ s:show_preview,
                                                                   \ ]),
                                                            \ 'v:val != "" ')
                                                       \ ,':')
                               \ ])},<bang>0))
