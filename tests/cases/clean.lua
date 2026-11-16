-- phases: 2
-- :Team clean deletes plugins on disk that no spec names, after asking; `!` does not ask.
-- A disabled plugin is still named by a spec, so it stays. Phase 1 installs three plugins;
-- phase 2 names only two, one of them disabled.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

local spec = { { H.src('libby'), load = 'trigger' }, { H.src('eps'), load = 'trigger' } }
if H.phase == 1 then
  spec[#spec + 1] = { H.src('solo'), load = 'trigger' }
else
  spec[2].enabled = false
end
require('team').setup({ confirm = false, teams_dir = false, spec = spec })

H.after_startup(function()
  H.wait_later()
  local ops, dir = require('team.ops'), require('team.pack').dir()
  if H.phase == 1 then
    H.eq(ops.strays(), {}, 'nothing to clean while every plugin is in a spec')
    vim.cmd('Team clean')
    H.ok(vim.uv.fs_stat(dir .. '/solo') ~= nil, 'nothing deleted')
    return
  end
  H.eq(ops.strays(), { 'solo' }, 'solo is in no spec; eps is disabled, but named')

  -- Asked, and answered no: nothing goes.
  local asked
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.confirm = function(msg)
    asked = msg
    return 2
  end
  vim.cmd('Team clean')
  H.ok(asked:find('solo', 1, true), 'it asked about solo')
  H.ok(vim.uv.fs_stat(dir .. '/solo') ~= nil, 'no: solo stays')

  vim.cmd('Team! clean')
  H.ok(not vim.uv.fs_stat(dir .. '/solo'), '! deletes without asking')
  H.ok(vim.uv.fs_stat(dir .. '/eps') ~= nil, 'the disabled plugin stays')
  local lock = vim.json.decode(table.concat(vim.fn.readfile(vim.fn.stdpath('config') .. '/nvim-pack-lock.json'), '\n'))
  H.eq(lock.plugins.solo, nil, 'and solo left the lockfile')
  H.eq(ops.strays(), {}, 'nothing left to clean')
end)
