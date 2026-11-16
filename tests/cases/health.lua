-- phases: 2
-- :checkhealth team: clean for a config with nothing wrong (phase 1); in phase 2 it lists
-- what was reported, the plugins by state, and a plugin on disk that no spec names.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

if H.phase == 1 then
  require('team').setup({
    confirm = false,
    teams_dir = false,
    spec = { { H.src('libby'), load = 'now' }, { H.src('solo'), load = 'trigger' } },
  })
else
  require('team').setup({
    confirm = false,
    teams_dir = false,
    spec = { { H.src('libby'), load = 'now', bogus = 1 }, { 'file:///nonexistent/ghost', load = 'now' } },
  })
end

H.after_startup(function()
  H.wait_later()
  local text = H.health('team')
  if H.phase == 1 then
    H.ok(not text:find('WARNING', 1, true) and not text:find('ERROR', 1, true), 'no warnings:\n' .. text)
    H.ok(text:find('OK setup() ran in', 1, true), 'setup ran')
    H.ok(text:find('OK nothing to warn about', 1, true), 'nothing reported')
    H.ok(text:find('plugins: 1 loaded, 1 installed', 1, true), 'plugins by state')
    H.ok(text:find('OK lockfile: ', 1, true), 'the lockfile')
    H.ok(text:find('OK every plugin on disk is in a spec', 1, true), 'no strays')
    return
  end
  H.ok(
    text:find('WARNING [^\n]*/health%.lua: `libby` has unknown field `bogus`; it is ignored'),
    'a warning:\n' .. text
  )
  H.ok(text:find("ERROR `ghost` is not installed: fatal: '/nonexistent/ghost'", 1, true), 'vim.pack, as git said it')
  H.ok(text:find('plugins: 1 loaded, 1 failed', 1, true), 'plugins by state')
  H.ok(text:find('WARNING on disk, in no spec: solo', 1, true), 'a stray')
  H.ok(text:find(':Team clean deletes them', 1, true), 'with advice')
  H.notes = {}
end)
