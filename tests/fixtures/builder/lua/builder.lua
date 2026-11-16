return {
  make = function()
    vim.g.builder_made = (vim.g.builder_made or 0) + 1
  end,
}
