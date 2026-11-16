" Defined without a bang, as many Vimscript plugins do: E174 if the name is taken.
command VimShared let g:vimshared = get(g:, 'vimshared', 0) + 1
