local M = {}
function M.setup(opts)
  vim.g.telescope_opts = opts
end
function M.load_extension(name)
  vim.g.telescope_extension = require('telescope._extensions.' .. name).built and name
end
return M
