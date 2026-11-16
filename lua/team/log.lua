-- Everything team.nvim did or noticed this session, newest last, up to `max` entries.

local M = {}

---@class team.LogEntry
---@field ms number since setup() started
---@field level integer
---@field msg string
---@field plugin? string
---@field team? string

M.max = 1000
---@type team.LogEntry[]
M.entries = {}
M.start = vim.uv.hrtime()

---@param level integer
---@param msg string
---@param about? { plugin?: string, team?: string }
---@return team.LogEntry
function M.add(level, msg, about)
  about = about or {}
  local e =
    { ms = (vim.uv.hrtime() - M.start) / 1e6, level = level, msg = msg, plugin = about.plugin, team = about.team }
  M.entries[#M.entries + 1] = e
  if #M.entries > M.max then
    table.remove(M.entries, 1)
  end
  return e
end

return M
