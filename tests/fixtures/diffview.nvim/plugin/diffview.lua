vim.api.nvim_create_user_command('DiffviewOpen', function()
  vim.g.diffview_opened = (vim.g.diffview_opened or 0) + 1
end, {})
