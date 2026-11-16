-- :checkhealth team

local M = {}

function M.check()
  local h = vim.health
  local state, log = require('team.state'), require('team.log')

  h.start('team.nvim')
  if vim.fn.has('nvim-0.12') == 1 then
    h.ok(('Neovim %s'):format(tostring(vim.version())))
  else
    h.error('team.nvim needs Neovim 0.12 or newer, for vim.pack')
  end
  if vim.fn.executable('git') == 1 then
    local r = vim.system({ 'git', '--version' }, { text = true }):wait()
    h.ok(vim.trim(r.stdout or 'git'))
  else
    h.error('git is not on your PATH: vim.pack needs it to install and update')
  end
  if not state.config then
    h.warn("setup() has not run: require('team').setup({ ... })")
    return
  end
  local count = { teams = #state.team_order, plugins = #state.order }
  h.ok(('setup() ran in %.2f ms: %d teams, %d plugins'):format(state.times.setup or 0, count.teams, count.plugins))

  h.start('team.nvim: config and loading')
  local problems = 0
  for _, e in ipairs(log.entries) do
    if e.level >= vim.log.levels.ERROR then
      h.error(e.msg)
      problems = problems + 1
    elseif e.level == vim.log.levels.WARN then
      h.warn(e.msg)
      problems = problems + 1
    end
  end
  if problems == 0 then
    h.ok('nothing to warn about')
  end
  local by_state = {}
  for _, name in ipairs(state.order) do
    local s = state.plugins[name].state
    by_state[s] = (by_state[s] or 0) + 1
  end
  local parts = {}
  for _, s in ipairs({ 'loaded', 'installed', 'missing', 'failed', 'disabled' }) do
    if by_state[s] then
      parts[#parts + 1] = ('%d %s'):format(by_state[s], s)
    end
  end
  h.info('plugins: ' .. (#parts > 0 and table.concat(parts, ', ') or 'none'))

  h.start('team.nvim: vim.pack')
  local lock = vim.fs.joinpath(vim.fn.stdpath('config') --[[@as string]], 'nvim-pack-lock.json')
  if vim.uv.fs_stat(lock) then
    h.ok('lockfile: ' .. vim.fn.fnamemodify(lock, ':~'))
  elseif #state.order > 0 then
    h.warn('no lockfile at ' .. vim.fn.fnamemodify(lock, ':~'))
  end
  local strays = require('team.ops').strays()
  if #strays > 0 then
    h.warn(('on disk, in no spec: %s'):format(table.concat(strays, ', ')), ':Team clean deletes them')
  else
    h.ok('every plugin on disk is in a spec')
  end
end

return M
