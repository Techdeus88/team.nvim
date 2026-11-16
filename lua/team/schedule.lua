-- The `later` queue, and your own functions on the same schedule. The queue starts once
-- the UI is up (VimEnter when no UI is coming) and loads in turn, within `budget` ms per
-- event-loop tick, so typing and drawing go on between plugins.

local events = require('team.events')

local M = {}

M.budget = 5

---@type (team.Plugin|function)[]
local queue = {}
local next_item = 1
local draining = false
local started = false
local drained_once = false
---@type function[] now() functions waiting for setup()'s `now` plugins
local waiting = {}
local ran_now = false

--- Whether a UI will attach, so UIEnter will fire. Headless Neovim never gets one; an
--- embedded one has its UI attached before init.lua runs, or is driven without one.
---@return boolean
function M.ui_coming()
  local argv = vim.v.argv
  if vim.list_contains(argv, '--headless') then
    return false
  end
  return #vim.api.nvim_list_uis() > 0 or not vim.list_contains(argv, '--embed')
end

--- Run one of your functions; an error is reported with where you wrote it.
---@param fn function
---@param when 'now'|'later'
local function run(fn, when)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    local info = debug.getinfo(fn, 'S')
    local where = ('%s:%d'):format(vim.fs.basename(info.short_src), info.linedefined)
    local msg = ('%s function at %s failed: %s'):format(when, where, tostring(err):match('^[^\n]*'))
    events.report(msg, vim.log.levels.ERROR)
  end
end

local function drain()
  local start = vim.uv.hrtime()
  local loader = require('team.loader')
  while next_item <= #queue do
    local x = queue[next_item]
    next_item = next_item + 1
    if type(x) == 'function' then
      run(x, 'later')
    elseif x.state == 'installed' or x.state == 'missing' or x.state == 'installing' then
      -- Anything else loaded meanwhile (a dependency, a trigger), failed, or is off. One
      -- still installing waits for its install and loads after it.
      loader.load(x, 'later')
    end
    if (vim.uv.hrtime() - start) / 1e6 >= M.budget then
      return vim.schedule(drain)
    end
  end
  draining = false
  if not drained_once then
    drained_once = true
    events.emit(events.names.Later, { ms = (vim.uv.hrtime() - require('team.log').start) / 1e6 })
  end
end

local function kick()
  if not draining then
    draining = true
    vim.schedule(drain)
  end
end

--- Add a plugin or one of your functions to the queue.
---@param x team.Plugin|function
function M.add(x)
  queue[#queue + 1] = x
  if started and vim.v.vim_did_enter == 1 then
    kick()
  end
end

--- Start the queue once the UI is up. setup() calls this after the `now` plugins.
function M.start()
  started = true
  if vim.v.vim_did_enter == 1 then
    return kick()
  end
  vim.api.nvim_create_autocmd(M.ui_coming() and 'UIEnter' or 'VimEnter', { once = true, callback = kick })
end

--- Run `fn` now: at once after setup(), else right after setup()'s `now` plugins.
---@param fn function
function M.now(fn)
  if ran_now then
    return run(fn, 'now')
  end
  waiting[#waiting + 1] = fn
end

--- Run the now() functions that waited for the `now` plugins.
function M.run_now()
  ran_now = true
  local fns = waiting
  waiting = {}
  for _, fn in ipairs(fns) do
    run(fn, 'now')
  end
end

--- Run `fn` in the `later` queue, in turn with the plugins there.
---@param fn function
function M.later(fn)
  M.add(fn)
end

return M
