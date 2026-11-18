-- phases: 2
-- Builds after install (phase 1) and update (phase 2): a shell command in the plugin's
-- folder, in the background, that a load waits for; a trigger that fires meanwhile is
-- replayed once it has loaded; an Ex command, which loads the plugin first; a function with
-- the plugin on the runtimepath but not loaded; an async one, and one that times out; a
-- Vimscript function by vim.fn, and a vararg Lua function, both run at once. A
-- build that fails runs again at the next startup.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

local fixed = vim.fs.joinpath(H.home, 'fixed')
if H.phase == 2 then
  -- What the failing build lacked in phase 1.
  vim.fn.writefile({}, fixed)
end
local delta_src, delta_dir = H.own('delta')
-- A build that runs until the case opens its gate, so the case sees it running.
local function gated(name, then_do)
  local gate = vim.fs.joinpath(H.home, 'gate-' .. name)
  return ('while [ ! -e %s ]; do sleep 0.05; done%s'):format(gate, then_do or '')
end
local function open_gate(name)
  vim.fn.writefile({}, vim.fs.joinpath(H.home, 'gate-' .. name))
end

---@type string[]
local built = {}
vim.api.nvim_create_autocmd('User', {
  pattern = 'TeamBuild',
  callback = function(ev)
    built[#built + 1] = ('%s %s %s'):format(ev.data.plugin, ev.data.kind, ev.data.ok and 'ok' or 'failed')
  end,
})
---@type string[]
local order = {}
vim.api.nvim_create_autocmd('User', {
  pattern = { 'TeamBuild', 'TeamPluginLoad' },
  callback = function(ev)
    order[#order + 1] = ev.match .. ' ' .. ev.data.plugin
  end,
})

local function sync_build(p)
  -- On the runtimepath, so require() works, but not loaded: plugin/ has not run.
  require('builder').make()
  vim.g.builder_plugin_during_build = vim.g.builder_plugin or 0
  vim.g.builder_state = p.state
end

require('team').setup({
  confirm = false,
  teams_dir = false,
  build_timeout = 3,
  teams = {
    shells = {
      load = 'now',
      plugins = {
        { H.src('libby'), build = gated('libby', ' && echo made > built.txt') },
        { H.src('gamma.nvim'), build = ('test -f %s || { echo "no fixed file" >&2; exit 3; }'):format(fixed) },
      },
    },
  },
  spec = {
    { H.src('argy'), cmd = 'Argy', build = gated('argy') },
    { H.src('cmdy'), load = 'trigger', build = ':CmdyBuild' },
    { H.src('builder'), load = 'trigger', build = sync_build },
    {
      H.src('eps'),
      load = 'trigger',
      build = function(_, done)
        vim.defer_fn(function()
          done(true)
        end, 50)
      end,
    },
    { H.src('solo'), load = 'trigger', build = function(_, _) end },
    { H.src('plainy'), load = 'trigger', build = vim.fn['plainy#build'] },
    {
      H.src('twomods'),
      load = 'trigger',
      build = function(...)
        vim.g.vararg_build = { select('#', ...), (...).name }
      end,
    },
    { delta_src, load = 'trigger', build = 'echo updated > built.txt' },
  },
})

H.after_startup(function()
  local team = require('team')
  local build = require('team.build')
  local function st(name)
    return team.get(name).state
  end

  if H.phase == 2 then
    H.wait(function()
      return vim.list_contains(built, 'gamma.nvim retry ok')
    end, 'the failed build to run again')
    H.eq(build.pending()['gamma.nvim'], nil, 'and to leave the pending list')
    H.eq(team.get('gamma.nvim').build_err, nil, 'with no error left')
    H.commit(delta_dir, 'delta 2')
    vim.cmd('Team update! delta')
    -- solo's build, which timed out in phase 1, runs again meanwhile: wait for delta's.
    H.wait(function()
      return vim.list_contains(built, 'delta update ok')
    end, 'a build after the update')
    H.eq(vim.fn.readfile(team.get('delta').path .. '/built.txt'), { 'updated' }, 'in its folder')
    return
  end

  -- A shell build in the background: the `now` plugin waits for it, then loads.
  H.eq(st('libby'), 'installed', 'libby waits for its build')
  H.eq(team.get('libby').building, gated('libby', ' && echo made > built.txt'), 'which is running')
  vim.cmd('Argy during build')
  H.eq({ st('argy'), _G.argy }, { 'installed', nil }, 'a command while argy builds waits')
  open_gate('libby')
  open_gate('argy')
  H.wait(function()
    return st('libby') == 'loaded' and st('argy') == 'loaded'
  end, 'the builds to end and the plugins to load', 4000)
  H.eq(vim.fn.readfile(team.get('libby').path .. '/built.txt'), { 'made' }, 'built in its folder')
  H.ok(
    vim.fn.index(order, 'TeamBuild libby') < vim.fn.index(order, 'TeamPluginLoad libby'),
    'built before loaded: ' .. table.concat(order, ', ')
  )
  H.eq(team.get('libby').reason, 'startup', 'loaded for the reason that asked')
  H.wait(function()
    return _G.argy ~= nil
  end, 'the command to be replayed')
  H.eq(_G.argy.args, 'during build', 'replayed once argy loaded')

  -- A failing build: reported, the plugin loads all the same, and it is pending.
  H.ok(H.noted('`gamma%.nvim`: build `test %-f .*` failed: exit 3: no fixed file'), 'the failure, with stderr')
  H.eq(st('gamma.nvim'), 'loaded', 'the plugin loads anyway')
  H.eq(build.pending()['gamma.nvim'], 'install', 'and its build is pending for the next startup')

  -- An Ex command: after VimEnter, with the plugin loaded first.
  H.wait(function()
    return vim.g.cmdy_built == 1
  end, ':CmdyBuild')
  H.eq({ st('cmdy'), team.get('cmdy').reason }, { 'loaded', 'build' }, 'cmdy loaded for its build')

  -- Functions: on the runtimepath, not loaded.
  H.wait(function()
    return vim.g.builder_made == 1
  end, 'the function build')
  H.eq({ vim.g.builder_plugin_during_build, st('builder') }, { 0, 'installed' }, 'plugin/ did not run; not loaded')
  H.wait(function()
    return vim.list_contains(built, 'eps install ok')
  end, 'the async build')
  H.wait(function()
    return vim.list_contains(built, 'solo install failed')
  end, 'the async build that never calls done', 5000)
  H.eq(team.get('solo').build_err, 'timed out after 3 s', 'times out')
  H.eq(vim.g.plainy_built, 1, 'a vim.fn build runs once, with no arguments')
  H.eq(team.get('plainy').build_err, nil, 'and succeeds')
  H.eq(vim.g.vararg_build, { 1, 'twomods' }, 'a vararg function gets the plugin, not done')
  H.ok(vim.list_contains(built, 'twomods install ok'), 'and finishes without a callback')
  H.eq(team.load('builder'), true, 'builder loads when asked')
  H.eq(vim.g.builder_plugin, 1, 'and its plugin/ runs then, once')
end)
