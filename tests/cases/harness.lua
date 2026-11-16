-- phases: 2
-- The harness itself: the case's dirs and git config are its own, team.nvim is on the
-- runtimepath, vim.pack installs from the fixtures, and what phase 1 installs is still
-- there in phase 2.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

local dir = vim.fs.joinpath(vim.fn.stdpath('data') --[[@as string]], 'site', 'pack', 'core', 'opt', 'alpha.nvim')
local was_on_disk = vim.uv.fs_stat(dir) ~= nil
vim.pack.add({ H.src('alpha.nvim') }, { confirm = false })

H.after_startup(function()
  for _, kind in ipairs({ 'config', 'data', 'state', 'cache' }) do
    local path = vim.fn.stdpath(kind) --[[@as string]]
    H.ok(vim.startswith(path, H.home), ('stdpath(%s) is under the case home: %s'):format(kind, path))
  end
  -- VIMRUNTIME is <prefix>/share/nvim/runtime; <prefix>/lib/nvim is on the runtimepath too.
  local prefix = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(assert(vim.env.VIMRUNTIME))))
  for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
    local ours = vim.startswith(path, H.home) or path == H.root or vim.startswith(path, prefix)
    H.ok(ours, 'runtimepath has only the case home, the repo and Neovim, not ' .. path)
  end
  H.eq(H.sh({ 'git', 'config', '--list' }, H.home), '', 'git sees no config of yours')
  H.eq(type(require('team')), 'table', 'team.nvim is on the runtimepath')

  H.eq(was_on_disk, H.phase == 2, 'phase 1 installs, phase 2 finds it on disk')
  H.eq({ vim.g.alpha_plugin, vim.g.alpha_after }, { 1, 1 }, 'plugin/ and after/plugin/ ran once each')
  H.eq(require('alpha').setup ~= nil, true, 'its module loads')

  local lock = vim.json.decode(table.concat(vim.fn.readfile(vim.fn.stdpath('config') .. '/nvim-pack-lock.json'), '\n'))
  local head = H.sh({ 'git', 'rev-parse', 'HEAD' }, vim.fs.joinpath(vim.env.TEAM_FIXTURES, 'alpha.nvim'))
  H.eq(lock.plugins['alpha.nvim'].rev, head, 'the lockfile has the fixture at its commit')
end)
