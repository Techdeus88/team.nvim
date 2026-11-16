-- Loading when things go wrong: each failure says which plugin and why, once; what
-- depends on a failed plugin or team fails with the reason; a team whose batch failed
-- runs no `post`; a failing hook is reported and loading carries on; everything else loads.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

_G.trace = {}
local function mark(s)
  return function()
    table.insert(_G.trace, s)
  end
end
---@type string[]
local failed = {}
vim.api.nvim_create_autocmd('User', {
  pattern = 'TeamPluginFail',
  callback = function(ev)
    failed[#failed + 1] = ev.data.plugin
  end,
})

require('team').setup({
  confirm = false,
  teams_dir = false,
  spec = {},
  teams = {
    core = { load = 'now', post = mark('post core'), plugins = { { H.src('broken.nvim'), opts = {} } } },
    dependents = { load = 'now', deps = { 'core' }, pre = mark('pre dependents'), plugins = { H.src('beta.nvim') } },
    misc = {
      load = 'now',
      post = mark('post misc'),
      plugins = {
        { H.src('twomods'), opts = {} },
        { H.src('nosetup'), config = true },
        { 'file:///nonexistent/ghost' },
        { H.src('gamma.nvim'), deps = { 'ghost' } },
        { H.src('solo'), opts = { s = 1 } },
        { H.src('nvim-dashed'), config = true },
        {
          H.src('libby'),
          opts = function()
            error('opts boom')
          end,
        },
        {
          H.src('delta'),
          config = function()
            error('config boom')
          end,
        },
        {
          H.src('alpha.nvim'),
          after = function()
            error('after boom')
          end,
        },
      },
    },
    hooks = {
      load = 'now',
      init = function()
        error('init boom')
      end,
      pre = function()
        error('pre boom')
      end,
      plugins = {
        {
          H.src('eps'),
          init = function()
            error('plugin init boom')
          end,
        },
      },
    },
  },
})

H.after_startup(function()
  local team, state = require('team'), require('team.state')
  local function row(name)
    local p = assert(team.get(name), name)
    return { p.state, p.err }
  end

  H.eq(row('broken.nvim')[1], 'failed', 'setup() raised')
  H.ok(row('broken.nvim')[2]:find('^`broken%.setup%(%)`: .*/lua/broken%.lua:3: setup boom$'), 'where it raised')
  H.eq(
    row('beta.nvim'),
    { 'failed', 'team `core`, which team `dependents` needs, did not load' },
    'a team it needs failed'
  )
  H.eq({ state.teams.core.state, state.teams.dependents.state }, { 'failed', 'failed' }, 'both teams failed')
  H.eq(row('twomods'), { 'failed', 'cannot tell which module gets `opts`; set `main` (found one, two)' }, 'no main')
  H.eq(row('nosetup'), { 'failed', '`nosetup.setup()`: module `nosetup` has no setup()' }, 'no setup()')
  H.eq(team.get('ghost').state, 'failed', 'a plugin that could not install fails to load')
  H.ok(team.get('ghost').err:find('git', 1, true), "with vim.pack's reason: " .. tostring(team.get('ghost').err))
  H.eq(row('gamma.nvim'), { 'failed', 'its dependency `ghost` did not load' }, 'so does what depends on it')
  H.eq(row('solo'), { 'loaded' }, 'the one module it has gets opts')
  H.eq(row('nvim-dashed'), { 'loaded' }, 'a module named like the plugin')
  H.eq(_G.opts.onlymod, { s = 1 }, 'solo got its opts')
  H.eq(_G.opts.dashed, 'none', 'config = true calls setup() with nothing')
  H.ok(row('libby')[2]:find('^`opts`: .*opts boom'), 'an opts function raised: ' .. row('libby')[2])
  H.ok(row('delta')[2]:find('^`config`: .*config boom'), 'config raised')
  H.ok(row('alpha.nvim')[2]:find('^`after`: .*after boom'), 'after raised')
  H.eq(state.teams.misc.state, 'failed', 'misc failed')
  H.eq(state.teams.misc.err, '`twomods` did not load', 'naming the first member that did not')
  for _, hook in ipairs({ 'post core', 'post misc', 'pre dependents' }) do
    H.ok(not vim.list_contains(_G.trace, hook), 'no post for a failed batch, no pre when needs failed: ' .. hook)
  end

  H.eq({ row('eps'), state.teams.hooks.state }, { { 'loaded' }, 'loaded' }, 'failing hooks do not stop a load')
  H.ok(H.noted('team `hooks`: `init` failed: .*init boom'), 'team init')
  H.ok(H.noted('team `hooks`: `pre` failed: .*pre boom'), 'team pre')
  H.ok(H.noted('`eps`: `init` failed: .*plugin init boom'), 'plugin init')

  H.eq(failed, {
    'broken.nvim',
    'beta.nvim',
    'twomods',
    'nosetup',
    'ghost',
    'gamma.nvim',
    'libby',
    'delta',
    'alpha.nvim',
  }, 'TeamPluginFail, once each')
  local function count(text)
    return #vim.tbl_filter(function(n)
      return n.msg:find(text, 1, true) ~= nil
    end, H.problems())
  end
  H.eq(count('config boom'), 1, 'one message per failure')
  H.eq(count('`ghost` is not installed'), 1, 'the missing plugin is reported once at install')
  H.eq(count('`ghost` did not load: '), 1, 'and once when it could not load')
  H.ok(H.noted('team `core` failed: `broken.nvim` did not load'), 'a failed team is reported')
  H.ok(
    vim.iter(H.problems()):all(function(n) ---@param n { level: integer }
      return n.level == vim.log.levels.ERROR
    end),
    'all of them as errors'
  )
end)
