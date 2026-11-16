-- collect.lua: where teams and specs are read from, and in what order: setup() teams by
-- name, then team files sorted by path, then spec roots in the order given. A file that
-- fails is reported and the others are still read.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

H.write('lua/teams/git.lua', {
  "return { event = 'BufReadPre', plugins = { 'o/signs', { 'o/diff', cmd = 'Diff' } } }",
})
H.write('lua/teams/lsp.lua', { "return { ft = 'lua' }" })
H.write('lua/teams/lsp/servers.lua', { "return { 'o/lspconfig', 'o/mason' }" })
H.write('lua/teams/lsp/more/deep.lua', { "return { 'o/deep' }" })
H.write('lua/teams/notes/one.lua', { "return 'o/onlyfolder'" })
H.write('lua/teams/list.lua', { "return { 'o/a', 'o/b' }" })
H.write('lua/teams/broken.lua', { 'return {' })
H.write('lua/teams/raises.lua', { "error('team file raised')" })
H.write('lua/teams/badplugins.lua', { "return { plugins = 'o/x' }" })
H.write('lua/plugins.lua', { "return { 'o/top' }" })
H.write('lua/plugins/a.lua', { "return { 'o/single', opts = {} }" })
H.write('lua/plugins/b.lua', { "return { { 'o/b1' }, 'o/b2' }" })
H.write('lua/plugins/sub/c.lua', { "return { 'o/c1' }" })
H.write('lua/plugins/nothing.lua', { 'return 42' })
local folder = vim.fs.joinpath(H.home, 'elsewhere')
H.write(vim.fs.joinpath(folder, 'x.lua'), { "return { 'o/fromdir' }" })
H.write(vim.fs.joinpath(folder, 'teamish/y.lua'), { "return { 'o/fromdir2' }" })

H.after_startup(function()
  local _, notes, c = H.build({
    teams = {
      zeta = { load = 'now', plugins = { 'o/z1' } },
      alpha = { plugins = { 'o/a1', { 'o/a2', ft = 'c' } } },
      bad = 'nope',
    },
    spec = { 'plugins', { 'o/inline' }, folder, 7 },
  })

  ---@param e team.Entry
  local function row(e)
    local s = e.spec
    local src = type(s) == 'string' and s or s[1]
    return ('%s %s'):format(e.team or '-', src)
  end
  H.eq(vim.tbl_map(row, c.entries), {
    -- setup() teams, by name
    'alpha o/a1',
    'alpha o/a2',
    'zeta o/z1',
    -- team files by path: git.lua, lsp.lua, lsp/more/deep.lua, lsp/servers.lua, notes/one.lua
    'git o/signs',
    'git o/diff',
    'lsp o/deep',
    'lsp o/lspconfig',
    'lsp o/mason',
    'notes o/onlyfolder',
    -- spec roots in order; a root's files by path, so lua/plugins.lua before lua/plugins/
    '- o/top',
    '- o/single',
    '- o/b1',
    '- o/b2',
    '- o/c1',
    '- o/inline',
    '- o/fromdir2',
    '- o/fromdir',
  }, 'entries in read order')

  H.eq(
    vim.tbl_map(function(d)
      return d.name
    end, c.teams),
    { 'alpha', 'zeta', 'badplugins', 'git', 'lsp', 'notes' },
    'team definitions in read order'
  )
  H.ok(c.teams[6].origin.file:find('/lua/teams/notes$'), 'a folder alone defines its team')
  H.eq(c.teams[2].fields, { load = 'now' }, 'a definition holds its fields, not its plugins')
  H.eq(c.teams[1].origin, { file = 'init.lua' }, 'setup() teams come from the file that called it')
  H.ok(c.teams[4].origin.file:find('/lua/teams/git.lua$'), 'a team file is its origin')
  H.ok(c.entries[5].origin.file:find('/lua/teams/git.lua$') and c.entries[5].origin.index == 2, 'entry origin')

  H.says(notes, 'init.lua: team `bad` should be a table like { load = ..., plugins = { ... } }; it is ignored')
  H.says(notes, 'lua/teams/list.lua: team `list` should be a table like')
  H.says(notes, 'team `badplugins`: `plugins` should be a list of specs; it is ignored')
  H.says(notes, 'lua/teams/broken.lua')
  H.says(notes, 'team file raised')
  H.says(notes, 'lua/plugins/nothing.lua: expected a spec or a list of specs, got number')
  H.says(notes, 'init.lua: setup(): `spec` holds a number; it is ignored')
  local broken = vim.tbl_map(function(f)
    return vim.fs.basename(f)
  end, c.broken)
  table.sort(broken)
  H.eq(broken, { 'broken.lua', 'nothing.lua', 'raises.lua' }, 'files that failed')

  local _, _, none = H.build({ teams_dir = false, spec = {} })
  H.eq({ #none.teams, #none.entries }, { 0, 0 }, 'teams_dir = false and no roots read nothing')
  local _, other_notes, other = H.build({ teams_dir = folder, spec = {} })
  H.eq(vim.tbl_map(row, other.entries), { 'teamish o/fromdir2' }, 'teams_dir can be a folder')
  H.eq(
    vim.tbl_map(function(d)
      return d.name
    end, other.teams),
    { 'teamish' },
    'its folders are teams'
  )
  H.says(other_notes, 'elsewhere/x.lua: team `x` should be a table like', 'and its top-level files team tables')
end)
