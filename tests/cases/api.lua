-- Loading after startup through the Lua API. The teams load on `trigger` with no trigger
-- of their own, so only something asking loads them: a plugin pulls in the batch of the team its
-- team needs, runs its team's `pre`, and sources its after/plugin/ files once; a team
-- loads its batch then the rest; a second setup() is ignored with a warning.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

_G.trace = {}
local function mark(s)
  return function()
    table.insert(_G.trace, s)
  end
end
---@type string[]
local loads = {}
vim.api.nvim_create_autocmd('User', {
  pattern = { 'TeamPluginLoad', 'TeamLoad' },
  callback = function(ev)
    loads[#loads + 1] = ('%s %s %s'):format(ev.match, ev.data.plugin or ev.data.team, ev.data.reason or '')
  end,
})

local team = require('team')
team.setup({
  confirm = false,
  teams_dir = false,
  spec = { { H.src('beta.nvim'), load = 'trigger' } },
  teams = {
    base = {
      load = 'trigger',
      -- Loading a member of its own team from `post` must not run `post` again.
      post = function()
        table.insert(_G.trace, 'post base')
        require('team').load('eps')
      end,
      plugins = { H.src('libby'), { H.src('eps'), load = 'trigger' } },
    },
    top = {
      load = 'trigger',
      deps = { 'base' },
      pre = mark('pre top'),
      post = mark('post top'),
      plugins = { { H.src('delta'), opts = {} }, H.src('gamma.nvim') },
    },
  },
})

H.after_startup(function()
  H.wait_later()
  H.eq(_G.trace, {}, 'nothing has loaded: nothing asked')
  H.eq(team.load('delta'), true, 'load() a plugin')
  H.eq(_G.trace, {
    'plugin libby',
    'post base',
    'plugin eps',
    'pre top',
    'plugin delta',
    'after delta',
    'require delta',
    'setup delta',
  }, 'the batch of the team it needs first, then pre, then the plugin with its after/plugin/')
  H.eq(team.get('libby').reason, 'team `top` needs it', 'why libby loaded')
  H.eq(team.get('delta').reason, 'load()', 'why delta loaded')
  H.eq(require('team.state').teams.top.state, 'partial', 'top is partial: gamma has not loaded')

  _G.trace = {}
  H.eq(team.load('delta'), true, 'a plugin that loaded already')
  H.eq(team.load_team('top'), true, 'load_team()')
  H.eq(_G.trace, { 'plugin gamma', 'post top' }, 'loads only what had not, then post')
  H.eq(require('team.state').teams.top.state, 'loaded', 'top loaded')
  H.eq(loads, {
    'TeamPluginLoad libby team `top` needs it',
    'TeamPluginLoad eps load()',
    'TeamLoad base ',
    'TeamPluginLoad delta load()',
    'TeamPluginLoad gamma.nvim load_team()',
    'TeamLoad top ',
  }, 'events')

  _G.trace = {}
  H.eq(team.load('beta.nvim'), true, 'a plugin in team default')
  H.eq(_G.trace, { 'plugin beta', 'after beta' }, 'after/plugin/ sourced once')

  H.eq({ team.load('nope') }, { false, 'no plugin is named `nope`' }, 'an unknown plugin')
  H.eq({ team.load_team('nope') }, { false, 'no team is named `nope`' }, 'an unknown team')
  H.eq(
    vim.tbl_map(function(t)
      return t.name
    end, team.teams()),
    { 'base', 'top', 'default' },
    'teams()'
  )
  team.setup({ teams = {} })
  H.ok(H.noted('setup%(%) runs once a session; this call is ignored'), 'a second setup()')
  H.eq(team.get('libby').state, 'loaded', 'which changed nothing')
end)
