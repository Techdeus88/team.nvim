-- :Team and its subcommands, with completion. plugin/team.lua defines the command;
-- everything here waits for setup().
--
--   :Team                      the status of every team and plugin
--   :Team load {name}...       load teams or plugins now, with what they need
--   :Team update[!] [{name}...] vim.pack.update(); ! applies without confirming
--                              (`:Team! update` works too, for every subcommand with a bang)
--   :Team enable {team}        turn a team on for this session
--   :Team disable {team}       turn a team off for this session
--   :Team clean[!]             delete plugins on disk that no spec names; ! without asking
--   :Team profile              load costs, slowest first
--   :Team log                  everything team.nvim did and noticed

local state = require('team.state')

local M = {}

--- An error the way Neovim shows one for a command you typed.
---@param msg string
local function fail(msg)
  vim.api.nvim_echo({ { 'team.nvim: ' .. msg } }, true, { err = true })
end

---@param ok boolean
---@param err? string
local function check(ok, err)
  if not ok and err then
    fail(err)
  end
end

---@type table<string, fun(args: string[], bang: boolean)>
M.subcommands = {
  load = function(args)
    if #args == 0 then
      return fail('load what? :Team load {team|plugin}...')
    end
    local loader = require('team.loader')
    for _, name in ipairs(args) do
      local t, p = state.teams[name], state.plugins[name]
      if t then
        if p then
          vim.api.nvim_echo({ { ('team.nvim: `%s` is a team and a plugin; loading the team'):format(name) } }, true, {})
        end
        check(loader.load_team(t, ':Team load'))
      elseif p then
        check(loader.load(p, ':Team load'))
      else
        fail(('no team or plugin is named `%s`'):format(name))
      end
    end
  end,
  update = function(args, bang)
    check(require('team.ops').update(args, bang))
  end,
  enable = function(args)
    if #args ~= 1 then
      return fail('enable which team? :Team enable {team}')
    end
    check(require('team.ops').enable(args[1]))
  end,
  disable = function(args)
    if #args ~= 1 then
      return fail('disable which team? :Team disable {team}')
    end
    check(require('team.ops').disable(args[1]))
  end,
  clean = function(_, bang)
    check(require('team.ops').clean(bang))
  end,
  profile = function()
    require('team.views').open('profile')
  end,
  log = function()
    require('team.views').open('log')
  end,
}

--- Run `:Team`.
---@param opts vim.api.keyset.create_user_command.command_args
function M.run(opts)
  if not state.config then
    return fail("setup() has not run: require('team').setup({ ... })")
  end
  local args = vim.deepcopy(opts.fargs)
  local sub = table.remove(args, 1)
  if not sub then
    require('team.views').open('status')
    return
  end
  -- `:Team update!` reads as it should: the bang on the subcommand is the command's.
  local bang = opts.bang
  if sub:sub(-1) == '!' then
    sub, bang = sub:sub(1, -2), true
  end
  local fn = M.subcommands[sub]
  if not fn then
    return fail(('unknown subcommand `%s`; :Team %s'):format(sub, table.concat(M.names(), '|')))
  end
  fn(args, bang)
end

---@return string[]
function M.names()
  local names = vim.tbl_keys(M.subcommands)
  table.sort(names)
  return names
end

---@param fn fun(name: string): boolean
---@return string[]
local function teams_where(fn)
  return vim.tbl_filter(fn, state.team_order)
end

--- What each subcommand's arguments can be.
---@type table<string, fun(): string[]>
local candidates = {
  load = function()
    local res = teams_where(function(n)
      local s = state.teams[n].state
      return s ~= 'loaded' and s ~= 'disabled'
    end)
    for _, p in ipairs(state.list(function(p)
      return p.state == 'installed' or p.state == 'missing'
    end)) do
      res[#res + 1] = p.name
    end
    return res
  end,
  update = function()
    local res = vim.list_slice(state.team_order)
    for _, p in ipairs(state.list(function(p)
      return p.path ~= nil
    end)) do
      res[#res + 1] = p.name
    end
    return res
  end,
  enable = function()
    return teams_where(function(n)
      return state.teams[n].state == 'disabled'
    end)
  end,
  disable = function()
    return teams_where(function(n)
      return state.teams[n].state ~= 'disabled'
    end)
  end,
}

--- Complete `:Team`.
---@param lead string
---@param line string
---@return string[]
function M.complete(lead, line)
  local words = vim.split(line, '%s+', { trimempty = true })
  -- The word being typed is not done yet: it is the lead.
  local done = #words - (lead ~= '' and 1 or 0)
  local list
  if done <= 1 then
    list = M.names()
  else
    local fn = candidates[words[2]]
    list = fn and fn() or {}
  end
  return vim.tbl_filter(function(c)
    return vim.startswith(c, lead)
  end, list)
end

return M
