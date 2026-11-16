-- spec.lua: every form a spec can be written in becomes one shape, problems warn and
-- fall back, specs of one plugin merge, and `opts` parts resolve in cinch's order.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

H.after_startup(function()
  local spec, notes_mod = require('team.spec'), require('team.notes')
  local notes = notes_mod.new()
  local at = { file = 'specs.lua' }
  ---@return team.Spec
  local function n(raw)
    return assert(spec.normalize(raw, at, notes))
  end

  -- Where it comes from, and its name, by vim.pack's rule.
  H.eq(n('owner/repo.nvim'), { src = 'https://github.com/owner/repo.nvim', name = 'repo.nvim' }, 'a string')
  H.eq(n({ 'owner/repo' }).src, 'https://github.com/owner/repo', '[1] is src')
  H.eq(n({ src = 'https://host/x/y.git' }).name, 'y', 'name drops .git')
  H.eq(n({ 'owner/repo', name = 'mine' }).name, 'mine', 'name set')
  H.eq(n({ 'owner/repo', name = 'a/b' }).name, 'b', 'a name with a slash keeps its last part, as vim.pack does')
  H.eq(n('./local/repo').src, './local/repo', 'a relative path is not a GitHub repo')
  H.eq(n('file:///tmp/x').src, 'file:///tmp/x', 'a URL stays')
  H.eq(spec.normalize({ opts = {} }, at, notes), nil, 'no src')
  H.says(notes, 'specs.lua: a spec without `src`')
  H.eq(spec.normalize(42, at, notes), nil, 'not a spec')
  H.says(notes, 'a spec is a string or a table, got number')
  H.eq(spec.normalize({ src = 'https://host/' }, at, notes), nil, 'no name')
  H.says(notes, 'no plugin name in `https://host/`')

  -- Versions: commit beats tag beats version beats branch; a range string is a range.
  H.eq(n({ 'o/pin', commit = 'abc', tag = 'v1' }).version, 'abc', 'commit beats tag')
  H.says(notes, '`pin` sets `commit` and `tag`; using `commit`')
  H.eq(n({ 'o/br', branch = 'dev' }).version, 'dev', 'branch alone')
  H.eq(n({ 'o/vb', version = 'v2', branch = 'dev' }).version, 'v2', 'version beats branch')
  local ranged = n({ 'o/rng', version = '^1.2' }).version --[[@as vim.VersionRange]]
  H.ok(getmetatable(ranged) ~= nil and ranged:has('1.3.0'), "'^1.2' becomes vim.version.range()")
  H.eq(n({ 'o/x1', version = '1.x' }).version, '1.x', "'1.x' stays as written")
  H.says(
    notes,
    "`x1` version `1.x` looks like a range, which vim.pack reads as a branch or tag; write vim.version.range('1.x')"
  )
  H.eq(n({ 'o/vf', version = false }).version, nil, 'version = false follows the default branch')
  H.eq(n({ 'o/vt', version = {} }).version, nil, 'a version table that is no range')
  H.says(notes, '`vt` has a `version` that is not a string or vim.version.range(); it is ignored')

  -- lazy.nvim's fields.
  H.eq(n({ 'o/l1', lazy = false }).load, 'now', 'lazy = false is now')
  H.eq(n({ 'o/l2', lazy = true }).load, 'trigger', 'lazy = true is trigger')
  H.eq(n({ 'o/l3', lazy = true, load = 'later' }).load, 'later', 'load beats lazy')
  H.eq(n({ 'o/dp', dependencies = { 'x/y' } }).deps, { 'x/y' }, 'dependencies is deps')
  H.eq(n({ 'o/both', deps = { 'a/b' }, dependencies = { 'x/y' } }).deps, { 'a/b' }, 'deps beats dependencies')

  -- cinch's `group` is read as `team`, with one note however often it comes.
  H.eq(n({ 'o/g1', group = 'git' }).team, 'git', 'group is team')
  H.eq(n({ 'o/g2', group = 'git', team = 'ui' }).team, 'ui', 'team beats group')
  local said = vim.tbl_filter(function(x)
    return x.msg:find('`group` is read as `team`', 1, true) ~= nil
  end, notes.list)
  H.eq(#said, 1, 'the group note comes once')
  H.eq(n({ 'o/t0', team = false }).team, false, 'team = false')

  -- Triggers become lists; false stays; a wrong type warns and is dropped.
  local t = n({ 'o/trig', event = 'BufRead', ft = { 'lua', 'c' }, cmd = false, keys = '<leader>f' })
  H.eq({ t.event, t.ft, t.cmd, t.keys }, { { 'BufRead' }, { 'lua', 'c' }, false, { '<leader>f' } }, 'trigger shapes')
  local fn = function() end
  H.eq(n({ 'o/k', keys = { { '<leader>g', fn, desc = 'go' }, 'gx' } }).keys, {
    { '<leader>g', fn, desc = 'go' },
    'gx',
  }, 'keys with a mapping')
  H.eq(n({ 'o/badtrig', cmd = 3, keys = { 4 } }).cmd, nil, 'a number is no command')
  H.says(notes, '`badtrig` field `cmd` should be a string, a list of strings or false; it is ignored')
  H.says(notes, "`badtrig` field `keys` should be a list of keys: '<lhs>' or { '<lhs>', rhs, ... }; it is ignored")

  -- Wrong types and unknown fields warn and are ignored, in name order.
  local bad = n({ 'o/bad', opts = 'x', load = 'soon', init = 1, priority = 1000, alpha = true })
  H.eq({ bad.opts_parts, bad.load, bad.init }, {}, 'bad values are dropped')
  H.says(notes, '`bad` field `opts` should be a table or a function, got string; it is ignored')
  H.says(notes, '`bad` has unknown load `soon`; it is ignored')
  H.says(notes, '`bad` field `init` should be a function, got number; it is ignored')
  local unknown = vim.tbl_filter(function(x)
    return x.msg:find('`bad` has unknown field', 1, true) ~= nil
  end, notes.list)
  H.eq(
    vim.tbl_map(function(x)
      return x.msg:match('field `(%w+)`')
    end, unknown),
    { 'alpha', 'priority' },
    'unknown fields, sorted'
  )

  -- Fields inside `data` win; the rest of `data` is yours and stays.
  local d = n({ 'o/data', load = 'now', data = { load = 'later', mine = 1 } })
  H.eq({ d.load, d.data }, { 'later', { mine = 1 } }, 'data')
  H.eq(n({ 'o/data2', data = { load = 'now' } }).data, nil, 'data with only fields leaves none')

  -- Your table is left as you wrote it.
  local raw = { 'o/raw', tag = 'v1', lazy = true, event = 'X', data = { load = 'now' } }
  local copy = vim.deepcopy(raw)
  n(raw)
  H.eq(raw, copy, 'normalize does not change its input')

  H.eq({ spec.is_ref('plenary.nvim'), spec.is_ref('o/r'), spec.is_ref('file:x') }, { true, false, false }, 'is_ref')
  H.eq({ spec.only_names(n('o/only')), spec.only_names(n({ 'o/more', opts = {} })) }, { true, false }, 'only_names')

  -- Merging: a later field replaces, lists whole; deps and opts parts add up; data merges.
  local f1 = function() end
  local m = spec.merge(
    n({ 'o/m', event = { 'A', 'B' }, deps = { 'x/a' }, opts = { a = 1 }, data = { k = { x = 1 } }, init = f1 }),
    n({ 'o/m', event = 'C', deps = { 'x/b' }, opts = { b = 2 }, data = { k = { y = 2 } }, main = 'mm' })
  )
  H.eq(m.event, { 'C' }, 'a later list replaces')
  H.eq(m.deps, { 'x/a', 'x/b' }, 'deps add up')
  H.eq(#m.opts_parts, 2, 'opts parts add up')
  H.eq(m.data, { k = { x = 1, y = 2 } }, 'data merges deep')
  H.eq({ m.init, m.main }, { f1, 'mm' }, 'other fields from both')
  H.eq(spec.merge(n({ 'o/f', load = 'now' }), n({ 'o/f', team = false })).team, false, 'false is a value')

  -- opts: tables and plain functions build the base, then functions taking opts extend it.
  local function resolve(...)
    return spec.resolve_opts({ ... }, {})
  end
  H.eq(
    resolve(function(_, o)
      o.b = 2
    end, { a = 1 }),
    { a = 1, b = 2 },
    'cinch example: an extending function runs after a table read later'
  )
  H.eq(
    resolve({ a = 1 }, function(_, o)
      o.a = 9
    end, { a = 2 }),
    { a = 9 },
    "an extending function's value beats every table"
  )
  H.eq(
    resolve(function()
      return { a = 1, n = { x = 1 } }
    end, { n = { y = 2 } }),
    { a = 1, n = { x = 1, y = 2 } },
    'a plain function is part of the base'
  )
  H.eq(
    resolve({ a = 1, b = 1 }, function(_, o)
      o.b = nil
    end),
    { a = 1 },
    'an extending function can remove a key'
  )
  H.eq(
    resolve({ a = 1 }, function(_, _)
      return { c = 3 }
    end),
    { a = 1, c = 3 },
    'a returned table merges in'
  )
  local base = { list = { 1 } }
  resolve(base, function(_, o)
    o.list[1] = 2
  end)
  H.eq(base, { list = { 1 } }, 'tables are copied before functions see them')
  local ok, err = pcall(resolve, function()
    return 'x'
  end)
  H.eq({ ok, err }, { false, 'an `opts` function returned a string, not a table' }, 'a function returns a non-table')
end)
