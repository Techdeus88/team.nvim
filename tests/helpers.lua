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

--- A fixture repo from tests/fixtures/ as a `src`.
---@param name string
---@return string
function H.src(name)
  return 'file://' .. vim.fs.joinpath(assert(vim.env.TEAM_FIXTURES), name)
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

--- Wait until `cond` holds, or fail after `ms`.
---@param cond fun(): boolean
---@param what string
---@param ms? integer
function H.wait(cond, what, ms)
  if not vim.wait(ms or 5000, cond, 10) then
    error('timed out waiting for ' .. what, 2)
  end
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
