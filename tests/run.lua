-- Usage: nvim -l tests/run.lua [filter ...]
--
-- Each file in tests/cases/ is the init.lua of its own headless Neovim, with its own XDG
-- dirs and no git config of yours. Plugins install from local git repos built from
-- tests/fixtures/, so no case needs the network. Cases run in parallel; a filter runs the
-- cases whose names contain it.
--
-- Header lines, the leading `--` comments of a case:
--   -- phases: N     run it N times over the same dirs, with TEAM_PHASE=1..N
--   -- args: a.md b  open these files, relative to the case's home, as command-line args
--
-- A case passes when every phase exits 0 after printing the marker H.done() writes.
--
-- Environment:
--   TEAM_TEST_CASES    folder of cases (default tests/cases)
--   TEAM_TEST_TMP      keep fixtures and case homes in a new folder under this one (default: a
--                      temp dir removed on exit)
--   TEAM_TEST_TIMEOUT  ms one phase may take (default 30000)
--   TEAM_TEST_JOBS     cases run at once (default: CPU count)

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(debug.getinfo(1, 'S').source:sub(2))))
local cases_dir = vim.fs.abspath(vim.env.TEAM_TEST_CASES or vim.fs.joinpath(root, 'tests', 'cases'))
local tmp = vim.env.TEAM_TEST_TMP
    and vim.fs.joinpath(vim.fs.abspath(vim.env.TEAM_TEST_TMP), os.date('run-%Y%m%d-%H%M%S'))
  or vim.fn.tempname()
local timeout = tonumber(vim.env.TEAM_TEST_TIMEOUT) or 30000
local jobs = math.max(1, tonumber(vim.env.TEAM_TEST_JOBS) or #vim.uv.cpu_info())
local marker = 'team: case done'

-- Your git config can sign commits, rewrite URLs or set hooks. The fixtures and every case
-- see none of it.
local git_env = {
  GIT_CONFIG_GLOBAL = '/dev/null',
  GIT_CONFIG_NOSYSTEM = '1',
  GIT_AUTHOR_NAME = 'team',
  GIT_AUTHOR_EMAIL = 'team@test',
  GIT_COMMITTER_NAME = 'team',
  GIT_COMMITTER_EMAIL = 'team@test',
}

---@param cmd string[]
---@param cwd? string
local function sh(cmd, cwd)
  local r = vim.system(cmd, { cwd = cwd, env = git_env, text = true }):wait()
  assert(r.code == 0, table.concat(cmd, ' ') .. '\n' .. (r.stderr or ''))
end

-- Each folder in tests/fixtures/ becomes a git repo with one commit on `main`.
local fixtures = vim.fs.joinpath(tmp, 'fixtures')
vim.fn.mkdir(fixtures, 'p')
for name, kind in vim.fs.dir(vim.fs.joinpath(root, 'tests', 'fixtures')) do
  local dir = vim.fs.joinpath(fixtures, name)
  if kind == 'directory' then
    sh({ 'cp', '-R', vim.fs.joinpath(root, 'tests', 'fixtures', name), dir })
    sh({ 'git', 'init', '-q', '-b', 'main' }, dir)
    sh({ 'git', 'add', '-A' }, dir)
    sh({ 'git', 'commit', '-q', '-m', 'init' }, dir)
  end
end

---@class team.test.Case
---@field name string
---@field file string
---@field home string
---@field phases integer
---@field args string[]

---@param file string
---@return team.test.Case
local function read_case(file)
  local name = vim.fn.fnamemodify(file, ':t:r')
  local home = vim.fs.joinpath(tmp, 'cases', name)
  local case = { name = name, file = file, home = home, phases = 1, args = {} }
  for line in io.lines(file) do
    if not line:find('^%-%-') then
      break
    end
    case.phases = tonumber(line:match('^%-%- phases: (%d+)')) or case.phases
    for word in (line:match('^%-%- args: (.*)') or ''):gmatch('%S+') do
      case.args[#case.args + 1] = vim.fs.joinpath(home, word)
    end
  end
  return case
end

local filters = _G.arg
---@type team.test.Case[]
local cases = {}
for _, file in ipairs(vim.fn.glob(vim.fs.joinpath(cases_dir, '*.lua'), false, true)) do
  local case = read_case(file)
  local wanted = #filters == 0
  for _, f in ipairs(filters) do
    wanted = wanted or case.name:find(f, 1, true) ~= nil
  end
  if wanted then
    cases[#cases + 1] = case
  end
end
if #cases == 0 then
  io.stdout:write('no cases match\n')
  os.exit(1)
end

---@param case team.test.Case
---@return table<string, string>
local function case_env(case)
  local env = vim.tbl_extend('force', git_env, {
    TEAM_ROOT = root,
    TEAM_FIXTURES = fixtures,
    TEAM_HOME = case.home,
    XDG_CONFIG_HOME = vim.fs.joinpath(case.home, 'config'),
    XDG_DATA_HOME = vim.fs.joinpath(case.home, 'data'),
    XDG_STATE_HOME = vim.fs.joinpath(case.home, 'state'),
    XDG_CACHE_HOME = vim.fs.joinpath(case.home, 'cache'),
    -- System dirs, such as a package manager's share/nvim/site, would add plugins.
    XDG_CONFIG_DIRS = vim.fs.joinpath(case.home, 'etc'),
    XDG_DATA_DIRS = vim.fs.joinpath(case.home, 'share'),
    -- Your NVIM_APPNAME would move the config dir away from the one made here.
    NVIM_APPNAME = 'nvim',
  })
  for _, dir in ipairs({ 'config/nvim', 'data', 'state', 'cache', 'etc', 'share' }) do
    vim.fn.mkdir(vim.fs.joinpath(case.home, dir), 'p')
  end
  return env
end

---@class team.test.Result
---@field ok boolean
---@field ms number
---@field why? string
---@field out? string

--- Run every phase of a case in turn, then call `done`.
---@param case team.test.Case
---@param done fun(r: team.test.Result)
local function run(case, done)
  local env = case_env(case)
  local cmd = vim.list_extend({ vim.v.progpath, '--headless', '-i', 'NONE', '-u', case.file }, case.args)
  local start = vim.uv.hrtime()
  local phase = 0
  local function next_phase()
    phase = phase + 1
    if phase > case.phases then
      return done({ ok = true, ms = (vim.uv.hrtime() - start) / 1e6 })
    end
    env.TEAM_PHASE = tostring(phase)
    vim.system(
      cmd,
      { env = env, text = true, timeout = timeout },
      vim.schedule_wrap(function(r)
        local stdout, stderr = r.stdout or '', r.stderr or ''
        local why
        if r.code == 124 then
          why = ('timed out after %d ms'):format(timeout)
        elseif r.code ~= 0 then
          why = ('exit %d'):format(r.code)
        elseif not stdout:find(marker, 1, true) then
          why = 'exited before its checks ran'
        end
        if why then
          local prefix = case.phases > 1 and ('phase %d '):format(phase) or ''
          return done({ ok = false, ms = (vim.uv.hrtime() - start) / 1e6, why = prefix .. why, out = stdout .. stderr })
        end
        next_phase()
      end)
    )
  end
  next_phase()
end

---@type table<string, team.test.Result>
local results = {}
local finished, started = 0, 0
local function start_next()
  started = started + 1
  local case = cases[started]
  if not case then
    return
  end
  run(case, function(r)
    results[case.name] = r
    finished = finished + 1
    io.stdout:write(
      ('%s %s (%.0f ms)%s\n'):format(r.ok and 'PASS' or 'FAIL', case.name, r.ms, r.why and (': ' .. r.why) or '')
    )
    start_next()
  end)
end
for _ = 1, math.min(jobs, #cases) do
  start_next()
end

-- Every phase ends by its own timeout, so this wait always ends first.
vim.wait(timeout * #cases * 10, function()
  return finished == #cases
end, 20)

local failed = {}
for _, case in ipairs(cases) do
  local r = results[case.name]
  if not (r and r.ok) then
    failed[#failed + 1] = case.name
    io.stdout:write(('\n--- %s: %s\n%s\n'):format(case.name, r and r.why or 'did not finish', r and r.out or ''))
  end
end
if vim.env.TEAM_TEST_TMP then
  io.stdout:write(('\nfixtures and homes kept in %s\n'):format(tmp))
end
io.stdout:write(
  #failed == 0 and ('\nall %d passed\n'):format(#cases) or ('\n%d of %d failed\n'):format(#failed, #cases)
)
os.exit(#failed == 0 and 0 or 1)
