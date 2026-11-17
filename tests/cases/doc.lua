-- doc/team.txt: helptags builds without a duplicate, `:h team` opens it, every link it
-- makes goes somewhere, and no line is wider than 78 columns.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

H.after_startup(function()
  -- A copy, so helptags writes its tags file in the case's folder, not the repo.
  local rt = vim.fs.joinpath(H.home, 'rt')
  vim.fn.mkdir(rt .. '/doc', 'p')
  local src = vim.fs.joinpath(H.root, 'doc', 'team.txt')
  local lines = vim.fn.readfile(src)
  vim.fn.writefile(lines, rt .. '/doc/team.txt')
  vim.opt.rtp:append(rt)
  vim.cmd.helptags(rt .. '/doc')
  H.eq(vim.v.errmsg, '', 'helptags: no duplicate tags')

  vim.cmd.help('team')
  H.eq(vim.fn.expand('%:t'), 'team.txt', ':h team')
  H.ok(vim.api.nvim_get_current_line():find('*team*', 1, true), 'on its tag')

  local tags, links = {}, {}
  for n, line in ipairs(lines) do
    H.ok(vim.fn.strdisplaywidth(line) <= 78, ('line %d is %d wide'):format(n, vim.fn.strdisplaywidth(line)))
    -- Inside a code block, |x| is text, not a link.
    for tag in line:gmatch('%*([^%s*|]+)%*') do
      H.ok(not tags[tag], 'tag defined once: ' .. tag)
      tags[tag] = true
    end
    if not line:find('^%s%s%s%s') then
      for link in line:gmatch('|([^%s|]+)|') do
        links[link] = links[link] or n
      end
    end
  end
  for link, n in pairs(links) do
    local ok = pcall(vim.cmd.help, link)
    H.ok(ok, ('line %d links to |%s|, which is no help tag'):format(n, link))
  end
  vim.v.errmsg = ''
  H.ok(lines[#lines]:find('vim:tw=78', 1, true), 'a modeline')
end)
