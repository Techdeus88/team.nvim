-- graph.lua, batches and on/off: which members load at their team's moment, teams and
-- plugins turned off, and dependencies nothing needs any more.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

H.after_startup(function()
  local g, notes = H.build({
    teams_dir = false,
    spec = {},
    teams = {
      git = {
        event = 'BufReadPre',
        plugins = {
          'o/signs',
          { 'o/diff', cmd = 'DiffviewOpen' },
          { 'o/early', load = 'now' },
          { 'o/owntrig', load = 'trigger' },
          { 'o/dropped', event = false },
          { 'o/off', enabled = false },
        },
      },
      later = { load = 'later', plugins = { { 'o/cmdlater', cmd = 'X' }, 'o/plainlater' } },
      plain = { plugins = { 'o/p1', { 'o/p2', cmd = 'P2' } } },
      gone = { enabled = false, load = 'now', plugins = { 'o/g1' } },
      condfn = {
        cond = function(t)
          return t.name ~= 'condfn'
        end,
        plugins = { 'o/c1' },
      },
      raises = {
        enabled = function()
          error('team check failed')
        end,
        load = 'later',
        plugins = {
          'o/r1',
          {
            'o/r2',
            cond = function(p)
              return p.name ~= 'r2'
            end,
          },
          {
            'o/r3',
            enabled = function()
              error('plugin check failed')
            end,
          },
        },
      },
      deps = {
        load = 'later',
        plugins = {
          { 'o/needsoff', enabled = false, deps = { { 'o/onlyforoff', deps = { { 'o/deeper' } } } } },
          { 'o/a', deps = { { 'o/shared' } } },
          { 'o/b', enabled = false, deps = { 'shared' } },
          { 'o/needsdisabled', deps = { 'off' } },
        },
      },
    },
  })
  local t = g.teams

  -- The batch: members that take the team's moment.
  H.eq(t.git.batch, { 'signs', 'diff' }, "git's batch")
  H.eq({ t.git.strategy, t.git.when }, { true, 'trigger' }, 'a team with a trigger loads on it')
  H.eq(
    g.plugins.diff.triggers,
    { event = { 'BufReadPre' }, cmd = { 'DiffviewOpen' } },
    'diff also loads alone on its cmd'
  )
  H.eq({ g.plugins.early.load, g.plugins.early.in_batch }, { 'now', nil }, 'its own load leaves the batch')
  H.eq(
    { g.plugins.owntrig.load, g.plugins.owntrig.triggers, g.plugins.owntrig.in_batch },
    { 'trigger', { event = { 'BufReadPre' } }, nil },
    "own load = 'trigger' takes the team's triggers but loads on its own"
  )
  H.eq({ g.plugins.dropped.load, g.plugins.dropped.in_batch }, { 'later', nil }, "dropping the team's only trigger too")
  H.eq(t.git.members, { 'signs', 'diff', 'early', 'owntrig', 'dropped', 'off' }, 'members, off ones too, in order')
  H.eq(t.later.batch, { 'cmdlater', 'plainlater' }, "a team's load puts every member in its batch")
  H.says(notes, '`cmdlater` is in team `later` with load = `later`, so its triggers are ignored')
  H.eq({ t.plain.strategy, t.plain.when, t.plain.batch }, { false, nil, {} }, 'a team with no strategy has no batch')
  H.eq({ g.plugins.p1.load, g.plugins.p2.load }, { 'later', 'trigger' }, 'its members load their own way')

  -- On and off.
  H.eq({ g.plugins.off.state, g.plugins.off.disabled_by }, { 'disabled', 'enabled' }, 'enabled = false')
  H.ok(not vim.list_contains(t.git.batch, 'off'), 'an off member is in no batch')
  H.eq({ t.gone.state, t.gone.disabled_by }, { 'disabled', 'enabled' }, 'a team turned off')
  H.eq({ g.plugins.g1.state, g.plugins.g1.disabled_by }, { 'disabled', 'team `gone`' }, 'turns off its members')
  H.eq({ t.condfn.state, t.condfn.disabled_by }, { 'disabled', 'cond' }, 'a cond function gets the team')
  H.eq(g.plugins.c1.state, 'disabled', 'and its member is off')
  H.eq({ t.raises.state, g.plugins.r1.state }, { 'pending', 'pending' }, 'a function that raises leaves it on')
  H.says(notes, 'init.lua: team `raises`: `enabled` raised an error, so it stays on: ')
  H.says(notes, 'team check failed')
  H.eq({ g.plugins.r2.state, g.plugins.r2.disabled_by }, { 'disabled', 'cond' }, 'a cond function gets the plugin')
  H.eq(g.plugins.r3.state, 'pending', 'a plugin check that raises leaves it on')
  H.says(notes, '`r3`: `enabled` raised an error, so it stays on: ')

  -- Dependencies nothing that is on needs.
  H.eq(g.plugins.onlyforoff.disabled_by, 'unneeded', 'a dependency only an off plugin needs is off')
  H.eq(g.plugins.deeper.disabled_by, 'unneeded', 'however deep')
  H.eq(g.plugins.shared.state, 'pending', 'a dependency something on needs stays on')
  H.says(notes, '`needsdisabled` depends on `off`, which is disabled')
  H.silent(notes, '`b` depends on', 'an off plugin with an off dependency says nothing')
end)
