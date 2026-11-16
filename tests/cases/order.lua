-- graph.lua, order: teams after the teams they need, ties in read order; a team pulled
-- earlier by a team that needs it; plugins in declaration order with deps first; and
-- cycles and bad names warned about and dropped.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

H.after_startup(function()
  local g, notes = H.build({
    teams_dir = false,
    spec = { { { 'o/loose', deps = { 'm2' } }, { 'o/free', team = false } } },
    teams = {
      -- Read in name order: alpha, base, cyc1, cyc2, mid, odd, plainteam, top, trig, ui, zeta.
      alpha = { load = 'later', deps = { 'zeta' }, plugins = { 'o/a1' } },
      zeta = { load = 'later', plugins = { 'o/z1' } },
      ui = { load = 'now', deps = { 'mid' }, plugins = { 'o/u1' } },
      mid = { load = 'later', deps = 'base', plugins = { { 'o/m1', deps = { 'b1' } }, 'o/m2' } },
      base = { event = 'BufRead', plugins = { 'o/b1' } },
      cyc1 = { load = 'later', deps = { 'cyc2' }, plugins = { 'o/c1' } },
      cyc2 = { load = 'later', deps = { 'cyc1' }, plugins = { 'o/c2' } },
      odd = {
        load = 'trigger',
        cmd = 'Odd',
        deps = { 'odd', 'nope', 'plainteam', 'trig' },
        plugins = { { 'o/o1', load = 'now' }, 'o/o2' },
      },
      plainteam = { plugins = { 'o/pt' } },
      trig = { cmd = 'Trig', plugins = { 'o/t1' } },
      top = {
        load = 'later',
        plugins = {
          { 'o/x', deps = { 'y' } },
          { 'o/y', deps = { 'x' } },
          { 'o/self', deps = { 'self', 'missing' } },
          { 'o/late', deps = { { 'o/libdep' } } },
        },
      },
    },
  })

  H.eq(g.team_order, {
    'zeta',
    'alpha',
    'base',
    'cyc2',
    'cyc1',
    'mid',
    'trig',
    'odd',
    'plainteam',
    'top',
    'ui',
    'default',
  }, 'needed teams first, ties in read order')
  H.says(notes, 'init.lua: teams form a cycle: cyc1 -> cyc2 -> cyc1; `cyc2` no longer needs `cyc1`')
  H.eq({ g.teams.cyc1.deps, g.teams.cyc2.deps }, { { 'cyc2' }, {} }, 'the edge that closes it is dropped')

  H.says(notes, 'team `odd` needs itself; it is ignored')
  H.says(notes, 'team `odd` needs team `nope`, which nothing defines; it is ignored')
  H.says(notes, 'team `odd` needs team `plainteam`, which has no load or trigger of its own; it is ignored')
  H.eq(g.teams.odd.deps, { 'trig' }, 'what is left')
  H.eq(g.teams.mid.deps, { 'base' }, 'deps can be one name')

  -- Pulls: ui (now) needs mid (later), which needs base (trigger): both load at startup.
  H.eq({ g.teams.mid.when, g.teams.mid.pulled_by }, { 'now', 'ui' }, 'a now team pulls a later one')
  H.eq({ g.teams.base.when, g.teams.base.pulled_by }, { 'now', 'mid' }, 'and that pull carries down the chain')
  H.says(notes, 'team `mid` loads at `now`, not `later`, because team `ui` needs it')
  H.says(notes, 'team `base` loads at `now`, not `trigger`, because team `mid` needs it')
  H.eq({ g.teams.trig.when, g.teams.trig.pulled_by }, { 'now', 'odd' }, "a member's own load counts")
  H.eq({ g.teams.zeta.when, g.teams.zeta.pulled_by }, { 'later', nil }, 'no pull when it is soon enough')
  H.eq(g.plugins.m1.load, 'later', "a plugin's own load stays as written")

  -- Plugins.
  H.says(notes, 'plugins form a cycle: x -> y -> x; `y` no longer depends on `x`')
  H.says(notes, '`self` depends on itself; it is ignored')
  H.says(notes, '`self` depends on `missing`, which no spec declares')
  H.eq(g.plugins.self.deps, {}, 'bad deps are dropped')
  H.eq(g.order, {
    'z1',
    'a1',
    'b1',
    'c2',
    'c1',
    'm1',
    'm2',
    't1',
    'o1',
    'o2',
    'pt',
    'y',
    'x',
    'self',
    'libdep',
    'late',
    'u1',
    'loose',
    'free',
  }, 'teams in order, members in declaration order, deps first, then the rest')

  -- `order`, lower first, those without one after; deps still come first.
  local o, onotes = H.build({
    teams_dir = false,
    spec = { { { 'o/t3', team = false, order = 2 }, { 'o/t4', team = false, order = 1 }, { 'o/t5', team = false } } },
    teams = {
      aa = { load = 'later', plugins = { 'o/aa1' } },
      bb = { load = 'later', order = 3, plugins = { 'o/bb1' } },
      cc = {
        load = 'later',
        order = 1,
        deps = { 'bb' },
        plugins = { { 'o/cc1', order = 2 }, { 'o/cc2', order = 1 }, 'o/cc3', { 'o/cc4', order = 1, deps = { 'cc3' } } },
      },
      dd = { load = 'later', order = 2, plugins = { 'o/dd1' } },
      bad = { order = 'first', plugins = { { 'o/bad1', order = {} } } },
    },
  })
  H.eq(o.team_order, { 'bb', 'cc', 'dd', 'aa', 'bad', 'default' }, 'teams by order; bb first, as cc needs it')
  H.eq(o.teams.cc.members, { 'cc2', 'cc4', 'cc1', 'cc3' }, 'members by order, then declaration')
  H.eq(o.teams.cc.batch, { 'cc2', 'cc4', 'cc1', 'cc3' }, 'the batch too')
  H.eq(
    o.order,
    { 'bb1', 'cc2', 'cc3', 'cc4', 'cc1', 'dd1', 'aa1', 'bad1', 't4', 't3', 't5' },
    'plugins: a dependency still comes first; plugins in no team by order at the end'
  )
  H.says(onotes, 'team `bad`: `order` should be a number, got string; it is ignored')
  H.says(onotes, '`bad1` field `order` should be a number, got table; it is ignored')
end)
