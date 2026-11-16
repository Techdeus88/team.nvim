-- Defines :Team. Nothing else runs until require('team').setup().
if vim.g.loaded_team then
  return
end
vim.g.loaded_team = true

vim.api.nvim_create_user_command('Team', function(opts)
  require('team.command').run(opts)
end, {
  nargs = '*',
  bang = true,
  desc = 'team.nvim',
  complete = function(lead, line)
    return require('team.command').complete(lead, line)
  end,
})
