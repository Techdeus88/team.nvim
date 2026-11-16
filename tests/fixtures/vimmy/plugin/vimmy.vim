" A FileType autocmd that calls a script-local function, as markdown-preview.nvim does.
augroup vimmy
  autocmd!
  autocmd FileType cnc call s:init()
augroup END
function! s:init() abort
  let b:vimmy = get(b:, 'vimmy', 0) + 1
endfunction
