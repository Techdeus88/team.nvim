-- Needs its build, as the real one needs its compiled library.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))))
assert(vim.uv.fs_stat(root .. '/built'), 'fzf: not built')
return { built = true }
