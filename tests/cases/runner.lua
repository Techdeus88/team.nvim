-- The runner fails a case every way one can go wrong, and passes the one that is right:
-- it runs itself over tests/runner_cases/ and reads what it reports.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

H.after_startup(function()
  local r = vim
    .system({ vim.v.progpath, '-l', vim.fs.joinpath(H.root, 'tests', 'run.lua') }, {
      env = { TEAM_TEST_CASES = vim.fs.joinpath(H.root, 'tests', 'runner_cases'), TEAM_TEST_TIMEOUT = '3000' },
      text = true,
    })
    :wait()
  local out = r.stdout or ''

  ---@type table<string, string>
  local verdicts = {}
  for line in out:gmatch('[^\n]+') do
    local verdict, name, why = line:match('^(%u+) (%S+) %(%d+ ms%)(.*)$')
    if verdict then
      verdicts[name] = verdict .. why
    end
  end
  H.eq(verdicts, {
    pass = 'PASS',
    check_fails = 'FAIL: exit 1',
    error_message = 'FAIL: exit 1',
    hangs = 'FAIL: timed out after 3000 ms',
    no_marker = 'FAIL: exited before its checks ran',
    second_phase = 'FAIL: phase 2 exit 1',
  }, 'each verdict')
  H.ok(out:find('expected 2, got 1', 1, true), "a failed check's message is shown")
  H.ok(out:find('error message during the case: .*boom'), 'so is the error message that failed a case')
  H.ok(out:find('5 of 6 failed', 1, true), 'the summary counts them')
  H.eq(r.code, 1, 'and the run exits 1')
end)
