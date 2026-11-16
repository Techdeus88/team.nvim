-- Loaded first by every case: `local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')`.
-- Puts team.nvim on the runtimepath, records every vim.notify, and runs the case's checks
-- once startup is done.

local H = {}

H.root = assert(vim.env.TEAM_ROOT, 'run cases with: nvim -l tests/run.lua')
H.home = assert(vim.env.TEAM_HOME)
H.phase = tonumber(vim.env.TEAM_PHASE) or 1
H.marker = 'team: case done'
vim.opt.rtp:prepend(H.root)

---@type { msg: string, level?: integer }[] every vim.notify, in order
H.notes = {}
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level)
  H.notes[#H.notes + 1] = { msg = tostring(msg), level = level }
end

-- Set once team.nvim's `later` queue has drained; wait for it with H.wait_later().
H.later_done = false
vim.api.nvim_create_autocmd('User', {
  pattern = 'TeamLater',
  once = true,
  callback = function()
    H.later_done = true
  end,
})

--- Wait for the `later` queue to drain.
function H.wait_later()
  H.wait(function()
    return H.later_done
  end, 'the later queue')
end

--- A fixture repo from tests/fixtures/ as a `src`.
---@param name string
---@return string
function H.src(name)
  return 'file://' .. vim.fs.joinpath(assert(vim.env.TEAM_FIXTURES), name)
end

--- A copy of a fixture that only this case uses, so it can add commits to it. Made once,
--- so later phases find it as phase 1 left it.
---@param name string
---@return string src, string dir
function H.own(name)
  local dir = vim.fs.joinpath(H.home, 'repos', name)
  if not vim.uv.fs_stat(dir) then
    vim.fn.mkdir(vim.fs.dirname(dir), 'p')
    H.sh({ 'git', 'clone', '-q', vim.fs.joinpath(assert(vim.env.TEAM_FIXTURES), name), dir })
  end
  return 'file://' .. dir, dir
end

--- Add a commit to a repo and return its hash.
---@param dir string
---@param msg string
---@return string
function H.commit(dir, msg)
  H.sh({ 'git', 'commit', '-q', '--allow-empty', '-m', msg }, dir)
  return H.sh({ 'git', 'rev-parse', 'HEAD' }, dir)
end

--- Run :checkhealth for `name` and return the report once it is written.
---@param name string
---@return string
function H.health(name)
  vim.cmd('checkhealth ' .. name)
  H.wait(function()
    return H.text():find('- ', 1, true) ~= nil
  end, 'the health report')
  return H.text()
end

--- A buffer's lines, joined.
---@param buf? integer default: the current one
---@return string
function H.text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false), '\n')
end

--- Run a command and return its trimmed stdout; raise when it fails.
---@param cmd string[]
---@param cwd? string
---@return string
function H.sh(cmd, cwd)
  local r = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert(r.code == 0, table.concat(cmd, ' ') .. '\n' .. (r.stderr or ''))
  return vim.trim(r.stdout or '')
end

---@param actual any
---@param expected any
---@param what? string
function H.eq(actual, expected, what)
  if not vim.deep_equal(actual, expected) then
    error(('%s: expected %s, got %s'):format(what or 'value', vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

---@param cond any
---@param what string
function H.ok(cond, what)
  if not cond then
    error(what, 2)
  end
end

--- Whether any vim.notify message matches the Lua `pattern`.
---@param pattern string
---@return boolean
function H.noted(pattern)
  for _, n in ipairs(H.notes) do
    if n.msg:find(pattern) then
      return true
    end
  end
  return false
end

--- Read config the way setup() will: options, then teams and specs, then the graph.
---@param opts? table setup() options
---@return team.Graph graph
---@return team.Notes notes
---@return team.Collected collected
function H.build(opts)
  local notes = require('team.notes').new()
  local origin = { file = 'init.lua' }
  local config = require('team.config').resolve(opts, origin, notes)
  local collected = require('team.collect').collect(config, origin, notes)
  return require('team.graph').build(collected, notes), notes, collected
end

--- Every note's message, for a failure to show.
---@param notes team.Notes
---@return string
local function listing(notes)
  local lines = vim.tbl_map(function(n)
    return '  ' .. n.msg
  end, notes.list)
  return #lines > 0 and table.concat(lines, '\n') or '  (none)'
end

--- Fail unless a note's message holds `text`, as is.
---@param notes team.Notes
---@param text string
---@param what? string
function H.says(notes, text, what)
  for _, n in ipairs(notes.list) do
    if n.msg:find(text, 1, true) then
      return
    end
  end
  error(('%s: no note says %q; notes:\n%s'):format(what or 'note', text, listing(notes)), 2)
end

--- Fail if a note's message holds `text`.
---@param notes team.Notes
---@param text string
---@param what? string
function H.silent(notes, text, what)
  for _, n in ipairs(notes.list) do
    if n.msg:find(text, 1, true) then
      error(('%s: a note says %q: %s'):format(what or 'note', text, n.msg), 2)
    end
  end
end

--- Wait until `cond` holds, or fail after `ms`.
---@param cond fun(): boolean
---@param what string
---@param ms? integer
function H.wait(cond, what, ms)
  if not vim.wait(ms or 5000, cond, 10) then
    error('timed out waiting for ' .. what, 2)
  end
end

--- Type keys as you would, and let what they scheduled run.
---@param keys string
function H.press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false)
  vim.wait(20)
end

--- Write `lines` to `path`. A relative path is under the case's config dir.
---@param path string
---@param lines string[]
function H.write(path, lines)
  if not vim.startswith(path, '/') then
    path = vim.fs.joinpath(vim.fn.stdpath('config') --[[@as string]], path)
  end
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
end

--- End the case: exit 0 with the pass marker, or 1 with `err` on stderr.
---@param err? string
function H.done(err)
  -- An error message from anywhere during the case fails it, so errors nobody checked
  -- for (a callback that raised, a bad autocmd) cannot pass unseen.
  if not err and vim.v.errmsg ~= '' then
    err = 'error message during the case: ' .. vim.v.errmsg
  end
  if err then
    io.stderr:write(err, '\n', 'notes: ', vim.inspect(H.notes), '\n')
    vim.cmd('cquit 1')
  else
    io.stdout:write(H.marker, '\n')
    vim.cmd('quitall!')
  end
end

--- Run `fn` once startup is done and anything it scheduled has run, then end the case.
---@param fn fun()
function H.after_startup(fn)
  vim.api.nvim_create_autocmd('VimEnter', {
    once = true,
    callback = function()
      -- Twice: work scheduled from VimEnter can schedule more.
      vim.schedule(function()
        vim.schedule(function()
          local ok, err = xpcall(fn, debug.traceback)
          H.done(not ok and err or nil)
        end)
      end)
    end,
  })
end

return H
