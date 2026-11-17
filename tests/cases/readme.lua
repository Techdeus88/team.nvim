-- README.md: its Lua blocks compile, its prose has no em dash or curly quote, and its
-- quick start runs as written. GitHub repos come from fixtures of the same name, so the
-- run needs no network: the colorscheme applies, which-key loads after ui, the git team
-- loads on BufReadPre, and <leader>ff builds fzf-native with make, loads telescope with
-- its extension, then runs the key.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

local text = table.concat(vim.fn.readfile(vim.fs.joinpath(H.root, 'README.md')), '\n')

-- owner/repo is GitHub; here it is the fixture named like the repo.
local spec = require('team.spec')
---@diagnostic disable-next-line: duplicate-set-field
spec.expand = function(src)
  local name = src:match('^[%w_.-]+/([%w_.-]+)$')
  return name and H.src(name) or src
end

local example = assert(text:match('<!%-%- example[^\n]*%-%->\n```lua\n(.-)\n```'), 'the quick start block')
assert(load(example, 'README quick start'))()

H.after_startup(function()
  H.wait_later()
  local blocks = 0
  for code in text:gmatch('```lua\n(.-)\n```') do
    blocks = blocks + 1
    local chunk, err = load(code, 'README block ' .. blocks)
    H.ok(chunk, err)
  end
  H.ok(blocks >= 6, 'every Lua block compiles: ' .. blocks)
  H.ok(not text:find('—', 1, true) and not text:find('[“”‘’]'), 'no em dash or curly quote')

  local team = require('team')
  local function st(name)
    return team.get(name).state
  end
  H.eq(H.problems(), {}, 'nothing to warn about')
  H.eq({ st('plenary.nvim'), st('tokyonight.nvim'), vim.g.colors_name }, { 'loaded', 'loaded', 'tokyonight' }, 'now')
  H.eq({ st('which-key.nvim'), team.get('which-key.nvim').reason }, { 'loaded', 'after team ui' }, 'after ui')
  H.eq({ st('gitsigns.nvim'), st('telescope.nvim') }, { 'installed', 'installed' }, 'the rest wait')

  vim.api.nvim_exec_autocmds('BufReadPre', { pattern = 'x.lua' })
  H.eq({ st('gitsigns.nvim'), st('diffview.nvim'), vim.g.gitsigns_opts }, { 'loaded', 'loaded', {} }, 'git')
  vim.cmd('DiffviewOpen')
  H.eq(vim.g.diffview_opened, 1, 'the real command')

  H.wait(function()
    return not team.get('telescope-fzf-native.nvim').building
  end, 'make to finish')
  H.press('<leader>ff')
  H.wait(function()
    return vim.g.telescope_ran ~= nil
  end, '<leader>ff to run')
  H.eq(vim.g.telescope_ran, 'find_files', '<leader>ff ran Telescope find_files')
  H.eq(vim.g.telescope_extension, 'fzf', 'with the fzf extension, built by make')
  H.eq(team.get('telescope.nvim').reason, 'keys <leader>ff', 'loaded by the key')
end)
