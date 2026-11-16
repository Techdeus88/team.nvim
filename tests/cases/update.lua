-- :Team update: vim.pack updates the plugins named, teams standing for their members;
-- `!` applies at once, without it vim.pack shows its confirmation buffer. A plugin that
-- has loaded is updated on disk and says to restart.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

local libby_src, libby_dir = H.own('libby')
local delta_src, delta_dir = H.own('delta')
require('team').setup({
  confirm = false,
  teams_dir = false,
  spec = {},
  teams = {
    core = { load = 'now', plugins = { libby_src } },
    lazy = { load = 'trigger', plugins = { delta_src } },
  },
})

---@param name string
---@return string
local function head(name)
  return H.sh({ 'git', 'rev-parse', 'HEAD' }, vim.fs.joinpath(require('team.pack').dir(), name))
end

---@param name string
---@return string
local function locked(name)
  local file = vim.fn.stdpath('config') .. '/nvim-pack-lock.json'
  return vim.json.decode(table.concat(vim.fn.readfile(file), '\n')).plugins[name].rev
end

H.after_startup(function()
  H.wait_later()
  local new_libby = H.commit(libby_dir, 'libby 2')
  local new_delta = H.commit(delta_dir, 'delta 2')
  H.ok(head('libby') ~= new_libby, 'libby is behind')

  vim.cmd('Team update! core')
  H.eq({ head('libby'), locked('libby') }, { new_libby, new_libby }, 'a team: its members updated, lockfile too')
  H.ok(head('delta') ~= new_delta, 'and only them')
  H.ok(H.noted('`libby` was updated while loaded; restart Neovim to run the new code'), 'a loaded plugin says so')

  vim.cmd('Team update lazy')
  H.ok(vim.api.nvim_buf_get_name(0):find('^nvim%-pack://confirm'), 'without !, the confirmation buffer')
  H.ok(head('delta') ~= new_delta, 'nothing applied yet')
  vim.cmd('write')
  H.wait(function()
    return head('delta') == new_delta
  end, 'delta updated once confirmed')
  H.silent({ list = H.notes }, '`delta` was updated', 'a plugin that has not loaded needs no restart')

  local ok, err = pcall(vim.cmd --[[@as function]], 'Team update nope')
  vim.v.errmsg = ''
  H.ok(not ok and tostring(err):find('no team or plugin is named `nope`', 1, true), 'unknown name')
end)
