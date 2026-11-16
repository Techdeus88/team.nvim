vim.api.nvim_create_user_command('CmdyBuild', function()
  vim.g.cmdy_built = (vim.g.cmdy_built or 0) + 1
end, {})
