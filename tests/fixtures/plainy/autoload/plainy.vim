" A build that takes no arguments: E118 if it is given any.
function! plainy#build() abort
  let g:plainy_built = get(g:, 'plainy_built', 0) + 1
endfunction
