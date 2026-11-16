-- :Team enable / disable for this session. Off: members that have not loaded never will,
-- their stubs go, and teams that need it cannot load. On: what it needs installs, its
-- `init` and its members' run, triggers come back, and what is past its moment queues.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

_G.trace = {}
local function mark(s)
  return function()
    table.insert(_G.trace, s)
  end
end

require('team').setup({
  confirm = false,
  teams_dir = false,
  spec = {},
  teams = {
    off = {
      enabled = false,
      load = 'later',
      init = mark('init off'),
      plugins = { { H.src('beta.nvim'), init = mark('init beta'), deps = { { H.src('libby') } } } },
    },
    lazy = { cmd = 'Argy', post = mark('post lazy'), plugins = { H.src('argy') } },
    needs = { load = 'trigger', deps = { 'lazy' }, plugins = { H.src('gamma.nvim') } },
    early = { load = 'now', plugins = { H.src('delta'), { H.src('eps'), load = 'trigger' } } },
  },
})

H.after_startup(function()
  H.wait_later()
  local team, state = require('team'), require('team.state')
  local function st(name)
    return team.get(name).state
  end
  local pack = require('team.pack')
  H.ok(not vim.uv.fs_stat(pack.dir() .. '/beta.nvim'), 'an off team is not installed')
  H.eq(st('libby'), 'disabled', 'nor the dependency only it needs')

  -- Off: the stub goes, members cannot load, nor teams that need it.
  vim.cmd('Team disable lazy')
  H.eq({ state.teams.lazy.state, st('argy') }, { 'disabled', 'disabled' }, 'lazy is off')
  H.eq(vim.fn.exists(':Argy'), 0, 'its command stub is gone')
  local loaded = pcall(vim.cmd --[[@as function]], 'Team load needs')
  vim.v.errmsg = ''
  H.eq({ loaded, st('gamma.nvim') }, { false, 'failed' }, 'a team that needs it cannot load')
  H.ok(H.noted('team `lazy`, which team `needs` needs, did not load'), 'and says why')
  local ok, err = pcall(vim.cmd --[[@as function]], 'Team disable lazy')
  vim.v.errmsg = ''
  H.ok(not ok and tostring(err):find('team `lazy` is already off', 1, true), 'twice')

  -- On again: the stub is back and works.
  vim.cmd('Team enable lazy')
  H.eq({ state.teams.lazy.state, st('argy') }, { 'pending', 'installed' }, 'lazy is on')
  vim.cmd('Argy again')
  H.eq({ st('argy'), _G.argy.args }, { 'loaded', 'again' }, 'its trigger loads it')
  H.ok(vim.list_contains(_G.trace, 'post lazy'), 'its post ran')

  -- A team off in config: on now, it installs, runs its init and its members', and loads in the queue.
  H.later_done = false
  vim.cmd('Team enable off')
  H.ok(vim.uv.fs_stat(pack.dir() .. '/beta.nvim') ~= nil, 'installed now')
  H.eq(vim.list_slice(_G.trace, #_G.trace - 1), { 'init off', 'init beta' }, 'team init, then the plugin init')
  H.wait(function()
    return st('beta.nvim') == 'loaded'
  end, 'beta to load in the queue')
  H.eq({ st('libby'), team.get('libby').reason }, { 'loaded', 'dependency of beta.nvim' }, 'with its dependency')
  H.eq(state.teams.off.state, 'loaded', 'and the team')

  -- Off with a member loaded: it stays, the rest never load.
  vim.cmd('Team disable early')
  H.eq({ st('delta'), st('eps') }, { 'loaded', 'disabled' }, 'loaded stays, the rest is off')
  H.ok(H.noted('team `early`: `delta` already loaded and stay until Neovim restarts'), 'and says so')
end)
