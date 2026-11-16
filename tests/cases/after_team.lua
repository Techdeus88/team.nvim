-- after_team: a team (or plugin) loads right after another team's batch has loaded.
-- Several waiting on one team load by `order`; chains carry on; it is a trigger only, so
-- another trigger can load it first; names that cannot work warn.
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
  spec = { { H.src('vimmy'), after_team = 'base' } },
  teams = {
    base = { load = 'now', order = 1, post = mark('post base'), plugins = { H.src('libby') } },
    next1 = { after_team = 'base', order = 2, pre = mark('pre next1'), plugins = { H.src('beta.nvim') } },
    next0 = { after_team = 'base', order = 1, plugins = { H.src('gamma.nvim') } },
    chain = { after_team = 'next1', plugins = { H.src('delta') } },
    oncmd = { cmd = 'Argy', plugins = { H.src('argy') } },
    afcmd = { after_team = 'oncmd', plugins = { H.src('plainy') } },
    either = { after_team = 'oncmd', event = 'User Early', plugins = { H.src('entery') } },
    bad = { after_team = { 'bad', 'nope' }, plugins = { H.src('solo') } },
    offt = { enabled = false, load = 'now', plugins = { H.src('nvim-dashed') } },
    waitsoff = { after_team = 'offt', plugins = { H.src('twomods') } },
  },
})
local at_setup = vim.deepcopy(_G.trace)

H.after_startup(function()
  H.wait_later()
  local team = require('team')
  local function row(name)
    local p = assert(team.get(name))
    return { p.state, p.reason, p.seq }
  end
  H.eq(at_setup, { 'post base', 'pre next1' }, 'during init.lua: base, then what waits for it')
  H.eq(row('libby'), { 'loaded', 'startup', 1 }, 'base')
  H.eq(row('gamma.nvim'), { 'loaded', 'after team base', 2 }, 'next0 first: order 1')
  H.eq(row('beta.nvim'), { 'loaded', 'after team base', 3 }, 'then next1: order 2')
  H.eq(row('delta'), { 'loaded', 'after team next1', 4 }, 'a chain carries on')
  H.eq(row('vimmy'), { 'loaded', 'after team base', 5 }, 'a plugin of its own after a team, after the teams')
  H.eq(require('team.state').teams.next1.state, 'loaded', 'next1 loaded')

  -- Trigger only: entery's own event loads it before oncmd has.
  vim.api.nvim_exec_autocmds('User', { pattern = 'Early' })
  H.eq({ row('entery')[1], row('argy')[1] }, { 'loaded', 'installed' }, 'another trigger first')
  vim.cmd('Argy x')
  H.eq(row('argy'), { 'loaded', 'cmd Argy', 8 }, 'oncmd on its command')
  H.eq(row('plainy'), { 'loaded', 'after team oncmd', 9 }, 'then the team after it')

  H.ok(H.noted('team `bad` loads after itself; it is ignored'), 'itself')
  H.ok(H.noted('team `bad` loads after team `nope`, which nothing defines; it is ignored'), 'undefined')
  H.eq(row('solo')[1], 'loaded', 'with nothing left, bad has no strategy: its member is later')
  H.ok(H.noted('team `waitsoff` loads after team `offt`, which is disabled'), 'disabled')
  H.eq(row('twomods')[1], 'installed', 'and never loads')
end)
