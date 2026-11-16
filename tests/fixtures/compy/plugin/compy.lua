vim.api.nvim_create_user_command('Comp', function() end, {
  nargs = 1,
  complete = function()
    return { 'one', 'two' }
  end,
})
