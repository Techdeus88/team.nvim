-- phases: 2
-- setup() at startup: vim.pack installs every plugin that is on (phase 1 only) without
-- loading it; team and plugin `init` run; `now` teams load in order, each after the teams
-- it needs, with `pre` before the first member and `post` after the batch; plugins in no
-- strategy load by their own `load`; events fire in order and each load is timed.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

_G.trace = {}
local function mark(s)
  return function()
    table.insert(_G.trace, s)
  end
end

---@type string[]
local seen = {}
local names = { 'TeamInstall', 'TeamLoadPre', 'TeamPluginLoadPre', 'TeamPluginLoad', 'TeamLoad', 'TeamSetup' }
for _, name in ipairs(names) do
  vim.api.nvim_create_autocmd('User', {
    pattern = name,
    callback = function(ev)
      local d = ev.data
      local what = d.plugin or d.team or (d.plugins and table.concat(d.plugins, ',')) or ''
      seen[#seen + 1] = vim.trim(name .. ' ' .. what)
      if name == 'TeamPluginLoad' or name == 'TeamLoad' or name == 'TeamSetup' then
        assert(type(d.ms) == 'number' and d.ms >= 0, name .. ' carries ms')
      end
    end,
  })
end

require('team').setup({
  confirm = false,
  teams_dir = false,
  spec = {
    { H.src('gamma.nvim'), load = 'now', opts = { g = 1 } },
    { H.src('eps'), load = 'now_if_args' },
  },
  teams = {
    core = {
      load = 'now',
      init = mark('init core'),
      pre = mark('pre core'),
      post = mark('post core'),
      plugins = { { H.src('libby'), opts = { l = 1 } }, { H.src('twomods'), main = 'one', opts = { o = 1 } } },
    },
    -- A `later` team that ui needs, so it loads at startup too, in its own place.
    early = { load = 'later', plugins = { { H.src('nvim-dashed'), config = true } } },
    ui = {
      load = 'now',
      deps = { 'core', 'early' },
      init = mark('init ui'),
      pre = mark('pre ui'),
      post = mark('post ui'),
      plugins = {
        {
          H.src('beta.nvim'),
          deps = { 'libby' },
          init = mark('init beta'),
          opts = function(_, o)
            o.b = 1
          end,
          after = mark('after() beta'),
        },
      },
    },
    lazy = { load = 'trigger', init = mark('init lazy'), pre = mark('pre lazy'), plugins = { H.src('delta') } },
    off = { enabled = false, init = mark('init off'), plugins = { H.src('solo') } },
    trig = { cmd = 'Trig', plugins = { H.src('alpha.nvim') } },
  },
})
local at_setup = vim.deepcopy(_G.trace)

H.after_startup(function()
  H.wait_later()
  local team, state = require('team'), require('team.state')
  local expected = {
    'init core',
    'init lazy',
    'init ui',
    'init beta',
    'pre core',
    'require libby',
    'setup libby',
    'require one',
    'setup one',
    'post core',
    'require dashed',
    'setup dashed',
    'pre ui',
    'require beta',
    'setup beta',
    'after() beta',
    'post ui',
    'require gamma',
    'setup gamma',
  }
  H.eq(at_setup, expected, 'setup(): inits, then each now team after the teams it needs')
  -- While init.lua runs, loading is `:packadd!`, as vim.pack does: startup then sources
  -- plugin/ and after/plugin/ once each. Each `:packadd` puts its plugin first on the
  -- runtimepath, so the last loaded is sourced first.
  vim.list_extend(expected, { 'plugin gamma', 'plugin beta', 'plugin libby', 'after beta' })
  -- Then the `later` queue: eps, now_if_args with no file.
  table.insert(expected, 'plugin eps')
  H.eq(_G.trace, expected, 'startup then sources plugin/ and after/plugin/ of what loaded, once')
  H.eq(
    _G.opts,
    { libby = { l = 1 }, one = { o = 1 }, dashed = 'none', beta = { b = 1 }, gamma = { g = 1 } },
    'setup() got each opts'
  )

  local function row(name)
    local p = assert(team.get(name), name)
    return { p.state, p.reason, p.seq }
  end
  H.eq(row('libby'), { 'loaded', 'startup', 1 }, 'libby')
  H.eq(row('twomods'), { 'loaded', 'startup', 2 }, 'twomods')
  H.eq(row('nvim-dashed'), { 'loaded', 'startup', 3 }, 'a pulled team loads at startup in its own place')
  H.eq(row('beta.nvim'), { 'loaded', 'startup', 4 }, 'beta')
  H.eq(row('gamma.nvim'), { 'loaded', 'startup', 5 }, "a plugin's own load = 'now'")
  H.eq(row('delta'), { 'installed' }, "a team with load = 'trigger' and no trigger waits to be asked")
  H.eq(row('alpha.nvim'), { 'installed' }, 'a trigger team waits for its trigger')
  H.eq(row('eps'), { 'loaded', 'later', 6 }, 'now_if_args without a file is later')
  H.eq(row('solo'), { 'disabled' }, 'an off team')
  H.eq(pcall(require, 'delta'), false, 'a plugin that has not loaded is not on the runtimepath')
  H.ok(not vim.uv.fs_stat(require('team.pack').dir() .. '/solo'), 'an off plugin is not installed')
  for _, name in ipairs({ 'libby', 'beta.nvim', 'gamma.nvim' }) do
    local time = team.get(name).time or {}
    H.ok(time.packadd >= 0 and time.config >= 0, name .. ' is timed')
  end

  local teams = {}
  for _, t in ipairs(team.teams()) do
    teams[#teams + 1] = t.name .. ' ' .. t.state
  end
  H.eq(
    teams,
    { 'core loaded', 'early loaded', 'lazy pending', 'off disabled', 'trig pending', 'ui loaded', 'default loaded' },
    'teams in order, with their states: default once eps loaded too, as it has no batch'
  )
  H.eq(state.teams.core.hooks.post ~= nil and state.teams.lazy.hooks.pre == nil, true, 'hooks timed, pre waits')

  local install = H.phase == 1 and { 'TeamInstall libby,twomods,nvim-dashed,delta,alpha.nvim,beta.nvim,gamma.nvim,eps' }
    or {}
  H.eq(
    seen,
    vim.list_extend(install, {
      'TeamLoadPre core',
      'TeamPluginLoadPre libby',
      'TeamPluginLoad libby',
      'TeamPluginLoadPre twomods',
      'TeamPluginLoad twomods',
      'TeamLoad core',
      'TeamLoadPre early',
      'TeamPluginLoadPre nvim-dashed',
      'TeamPluginLoad nvim-dashed',
      'TeamLoad early',
      'TeamLoadPre ui',
      'TeamPluginLoadPre beta.nvim',
      'TeamPluginLoad beta.nvim',
      'TeamLoad ui',
      'TeamLoadPre default',
      'TeamPluginLoadPre gamma.nvim',
      'TeamPluginLoad gamma.nvim',
      'TeamSetup',
      'TeamPluginLoadPre eps',
      'TeamPluginLoad eps',
      'TeamLoad default',
    }),
    'events, in order; phase 2 installs nothing'
  )

  local lock = vim.json.decode(table.concat(vim.fn.readfile(vim.fn.stdpath('config') .. '/nvim-pack-lock.json'), '\n'))
  local locked = vim.tbl_keys(lock.plugins)
  table.sort(locked)
  H.eq(
    locked,
    { 'alpha.nvim', 'beta.nvim', 'delta', 'eps', 'gamma.nvim', 'libby', 'nvim-dashed', 'twomods' },
    'the lockfile has every plugin that is on'
  )
  local loaded = vim.tbl_filter(function(e)
    return e.msg:find('^loaded `libby` %(startup%) in')
  end, require('team.log').entries)
  H.eq(#loaded, 1, 'the log has each load')
  for _, k in ipairs({ 'specs', 'pack', 'init', 'now', 'setup' }) do
    H.ok(state.times[k] >= 0, 'setup step timed: ' .. k)
  end
  H.eq(#H.problems(), 1, 'one warning')
  H.ok(H.noted('team `early` loads at `now`, not `later`, because team `ui` needs it'), 'about the pull')
end)
