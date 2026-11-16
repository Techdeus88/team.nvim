-- config.lua: setup() options. Yours where they are right; a wrong type warns and keeps
-- the default; an unknown option warns.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

H.after_startup(function()
  local config, notes_mod = require('team.config'), require('team.notes')
  local at = { file = 'init.lua' }
  local function resolve(opts)
    local notes = notes_mod.new()
    return config.resolve(opts, at, notes), notes
  end

  local defaults = {
    teams = {},
    teams_dir = 'teams',
    spec = { 'plugins' },
    confirm = true,
    budget = 5,
    ui = { size = 0.8 },
    build_timeout = 300,
  }
  H.eq(resolve(nil), defaults, 'nothing given')
  H.eq(resolve({}), defaults, 'an empty table')

  local c, notes = resolve('x')
  H.eq(c, defaults, 'not a table')
  H.says(notes, 'init.lua: setup() takes a table, got string; using the defaults')

  local teams = { git = { load = 'later' } }
  c, notes = resolve({
    teams = teams,
    teams_dir = false,
    spec = 'mine',
    confirm = false,
    budget = 2,
    ui = { border = 'single' },
  })
  H.eq(c, {
    teams = teams,
    teams_dir = false,
    spec = { 'mine' },
    confirm = false,
    budget = 2,
    ui = { size = 0.8, border = 'single' },
    build_timeout = 300,
  }, 'yours, one spec root as a list')
  H.eq(notes.list, {}, 'and no notes')
  H.eq(resolve({ spec = { 'a', { 'o/r' } } }).spec, { 'a', { 'o/r' } }, 'roots and inline specs')

  c, notes = resolve({
    teams = { 'git' },
    teams_dir = 1,
    spec = { a = 1 },
    confirm = 'no',
    budget = 0,
    ui = { size = 2 },
    bogus = 5,
    zed = true,
  })
  H.eq(c, defaults, 'wrong types keep the defaults')
  H.says(notes, 'setup(): `teams` should be a table of teams by name, got table; using the default')
  H.says(notes, 'setup(): `teams_dir` should be a module path, a folder or false, got number; using the default')
  H.says(notes, 'setup(): `spec` should be a module path, a folder, or a list of them and specs, got table')
  H.says(notes, 'setup(): `confirm` should be a boolean, got string; using the default')
  H.says(notes, 'setup(): `budget` should be a number of ms above 0, got number; using the default')
  H.says(notes, 'setup(): `ui` should be { size = 0.3 to 1, border = a string or list }, got table; using the default')
  H.eq(
    vim.tbl_map(function(x)
      return x.msg:match('unknown option `(%w+)`')
    end, vim.list_slice(notes.list, #notes.list - 1)),
    { 'bogus', 'zed' },
    'unknown options, sorted'
  )

  H.ok(resolve(nil) ~= resolve(nil), 'each call gets its own defaults')
end)
