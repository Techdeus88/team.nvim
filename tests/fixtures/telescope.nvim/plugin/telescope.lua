vim.api.nvim_create_user_command('Telescope', function(a)
  vim.g.telescope_ran = a.args
end, { nargs = '*' })
