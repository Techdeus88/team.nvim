-- graph.lua, teams and their members: who is in which team, how definitions and specs of
-- one name merge, and what a member inherits. Ported from cinch's groups.lua where the
-- rules are the same.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

H.write('lua/teams/git.lua', {
  'return {',
  "  load = 'now',",
  '  bogus = 1,',
  '  plugins = {',
  "    'o/signs',",
  "    { 'o/diff', cmd = 'Diff' },",
  "    { 'o/withdep', deps = { { 'o/wrapdep' }, { 'o/lib', opts = { b = 2 }, main = 'nested' }, 'o/libx' } },",
  '  },',
  '}',
})
H.write('lua/teams/ins.lua', {
  'return {',
  "  ft = 'markdown',",
  '  plugins = {',
  "    'o/cmp',",
  "    { 'o/snip', cmd = 'Snip' },",
  "    { 'o/ownevent', event = 'BufRead' },",
  "    { 'o/noevent', event = false },",
  "    { 'o/nowins', load = 'now' },",
  "    { 'o/trigins', load = 'trigger', cmd = 'TI' },",
  '  },',
  '}',
})
H.write('lua/teams/lsp.lua', { "return { ft = { 'lua' } }" })
H.write('lua/teams/lsp/servers.lua', {
  'return {',
  "  'o/lspconfig',",
  "  { 'o/fielded', team = 'ins' },",
  "  { 'o/grouped', group = 'ins' },",
  "  { 'o/opted', team = false },",
  "  { 'o/ghost', team = 'nope' },",
  "  { 'o/dirparent', deps = { { 'o/dirdep' } } },",
  '}',
})
H.write('lua/teams/zz.lua', { "return { plugins = { 'o/signs', 'o/tabs' } }" })
H.write('lua/plugins/a.lua', {
  'return {',
  "  { 'o/cmp', cmd = 'Cmp' },",
  "  { 'o/plain' },",
  "  { 'o/lib', opts = { a = 1 }, main = 'own' },",
  "  { 'fork/libx' },",
  "  { 'o/vl', event = 'VeryLazy' },",
  "  { 'o/vl2', event = { 'VeryLazy', 'BufRead' } },",
  "  { 'o/needsplain', deps = { 'plain' } },",
  '}',
})

H.write('lua/plugins/filed.lua', {
  'return {',
  "  event = 'BufRead',",
  "  { 'o/filed1' },",
  "  { 'o/filed2', cmd = 'F2' },",
  '}',
})
H.write('lua/plugins/named.lua', {
  'return {',
  "  team = 'custom',",
  "  load = 'now',",
  "  { 'o/named1' },",
  '}',
})

H.after_startup(function()
  local g, notes = H.build({
    teams = {
      git = { load = 'later' },
      ins = { event = 'InsertEnter' },
      real = { cmd = 'RealCmd', plugins = { 'o/real' } },
      badload = { load = 'soon', plugins = { 'o/bl' } },
      vlteam = { event = 'VeryLazy', plugins = { 'o/vlm' } },
    },
  })
  ---@return any[] # its team, load and triggers
  local function of(name)
    local p = assert(g.plugins[name], name)
    return { p.team or false, p.load, p.triggers }
  end

  -- Team tables and files: one name is one team, later fields win.
  H.eq(of('real'), { 'real', 'trigger', { cmd = { 'RealCmd' } } }, "a setup() team's member takes its trigger")
  H.eq(of('signs'), { 'git', 'now', {} }, 'a team defined in setup() and a file is one: the later load wins')
  H.says(notes, 'lua/teams/git.lua: team `git` has unknown field `bogus`; it is ignored', 'unknown team field')
  H.eq(of('diff'), { 'git', 'now', {} }, "a team's load is explicit: it wins over a member's trigger")
  H.says(notes, '`diff` is in team `git` with load = `now`, so its triggers are ignored', 'and says so')
  H.eq(g.plugins.diff.load_from, 'git', 'load came from the team')
  H.eq(of('bl'), { 'badload', 'later', {} }, "a team's unknown load is ignored")
  H.says(notes, 'team `badload` has unknown load `soon`; it is ignored', 'with a warning')

  -- Inheritance, field by field.
  H.eq(of('cmp'), {
    'ins',
    'trigger',
    { event = { 'InsertEnter' }, ft = { 'markdown' }, cmd = { 'Cmp' } },
  }, "setup() and file merge, and a spec from another file adds its own cmd beside the team's")
  H.eq(
    of('snip'),
    { 'ins', 'trigger', { event = { 'InsertEnter' }, ft = { 'markdown' }, cmd = { 'Snip' } } },
    'own cmd'
  )
  H.eq(
    of('ownevent'),
    { 'ins', 'trigger', { event = { 'BufRead' }, ft = { 'markdown' } } },
    "own event over the team's"
  )
  H.eq(of('noevent'), { 'ins', 'trigger', { ft = { 'markdown' } } }, "false drops one of the team's triggers")
  H.eq(of('nowins'), { 'ins', 'now', {} }, "its own load takes none of the team's triggers")
  H.silent(notes, '`nowins`', 'and nothing warns')
  H.eq(
    of('trigins'),
    { 'ins', 'trigger', { event = { 'InsertEnter' }, ft = { 'markdown' }, cmd = { 'TI' } } },
    'own trigger load takes them'
  )
  H.eq(g.plugins.cmp.inherited, { event = true, ft = true }, 'what it inherited')

  -- Membership: the spec's own team, else the list or folder, else default.
  H.eq(of('lspconfig'), { 'lsp', 'trigger', { ft = { 'lua' } } }, "a spec in a team's folder is in it")
  H.eq(of('fielded')[1], 'ins', "a spec's team field beats its folder")
  H.eq(of('grouped')[1], 'ins', "cinch's group field works as team")
  H.eq(of('opted'), { false, 'later', {} }, 'team = false leaves it')
  H.eq(of('ghost')[1], 'lsp', 'a team nothing defines is ignored: its folder has it')
  H.says(notes, '`ghost` names team `nope`, which nothing defines; it is ignored', 'with a warning')
  H.eq(of('signs')[1], 'git', 'listed by two teams, the first read keeps it')
  H.says(notes, 'lua/teams/zz.lua: `signs` is already in team `git`; team `zz` is ignored', 'and the second warns')
  H.eq(of('tabs')[1], 'zz', 'a team file with only plugins')
  H.eq(of('plain'), { 'default', 'later', {} }, 'a plain spec is in team default')

  -- Dependencies nested in a member are not members because of where they are nested.
  H.eq(of('wrapdep'), { false, 'trigger', {} }, 'a nested dependency is in no team and loads with its dependent')
  H.eq(g.plugins.wrapdep.dep_only, true, 'it is only a dependency')
  H.eq(of('dirdep')[1], false, "a nested dependency is not in its file's team")
  H.eq(g.plugins.withdep.deps, { 'wrapdep', 'lib', 'libx' }, 'deps by name')
  H.eq(g.plugins.needsplain.deps, { 'plain' }, 'a bare name refers to a spec')

  -- Specs of one plugin merge; a spec nested in deps applies over its own, whichever is read first.
  H.eq(g.plugins.lib.spec.main, 'nested', 'the nested spec wins')
  H.eq(g.plugins.lib.spec.opts_parts, { { a = 1 }, { b = 2 } }, 'its opts come after the own spec')
  H.eq({ g.plugins.lib.team, g.plugins.lib.dep_only }, { 'default', nil }, 'a dependency with its own spec is a member')
  H.eq(g.plugins.libx.spec.src, 'https://github.com/fork/libx', 'a dependency that only names it keeps your src')

  -- lazy.nvim's VeryLazy.
  H.eq(of('vl'), { 'default', 'later', {} }, 'VeryLazy alone is later')
  H.eq(of('vl2'), { 'default', 'trigger', { event = { 'BufRead' } } }, 'beside other events it is dropped')
  H.eq(g.plugins.vl2.very_lazy, true, 'and kept as a deadline')
  H.eq({ of('vlm'), g.teams.vlteam.when }, { { 'vlteam', 'later', {} }, 'later' }, 'a VeryLazy team is later')

  -- Team default is a team like the others: give it a strategy, and team = false escapes it.
  local d, dnotes = H.build({
    teams = { default = { load = 'now' } },
    teams_dir = false,
    spec = { { { 'o/loose' }, { 'o/out', team = false } } },
  })
  H.eq(
    { d.plugins.loose.team, d.plugins.loose.load, d.plugins.loose.load_from },
    { 'default', 'now', 'default' },
    'default team'
  )
  H.eq({ d.plugins.out.team, d.plugins.out.load }, { nil, 'later' }, 'team = false escapes it')
  H.eq(dnotes.list, {}, 'no notes')
  H.eq(d.teams.default.origin, { file = 'init.lua' }, 'default defined in setup()')

  -- A spec file with fields beside its list is a team: named by `team`, else by the file.
  H.eq(of('filed1'), { 'filed', 'trigger', { event = { 'BufRead' } } }, 'a spec file is a team named after it')
  H.eq(of('filed2'), { 'filed', 'trigger', { event = { 'BufRead' }, cmd = { 'F2' } } }, 'its members inherit')
  H.eq(of('named1'), { 'custom', 'now', {} }, 'its `team` field names the team over the file name')
end)
