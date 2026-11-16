-- Problems found while reading config. Each is a message with a level, recorded once;
-- the code that finds one carries on with a fallback. setup() reports them.

---@class team.Origin
---@field file string where it was written: a spec file, or the file that called setup()
---@field index? integer its place in that file's list

---@class team.Note
---@field msg string
---@field level integer

---@class team.Notes
---@field list team.Note[]
---@field seen table<string, true>
local Notes = {}
Notes.__index = Notes

local M = {}

---@return team.Notes
function M.new()
  return setmetatable({ list = {}, seen = {} }, Notes)
end

--- The file as a message names it.
---@param origin team.Origin
---@return string
function M.where(origin)
  return vim.fn.fnamemodify(origin.file, ':~')
end

---@param level integer
---@param origin? team.Origin
---@param msg string
function Notes:add(level, origin, msg)
  if origin then
    msg = ('%s: %s'):format(M.where(origin), msg)
  end
  if not self.seen[msg] then
    self.seen[msg] = true
    self.list[#self.list + 1] = { msg = msg, level = level }
  end
end

---@param origin? team.Origin
---@param msg string
function Notes:warn(origin, msg)
  self:add(vim.log.levels.WARN, origin, msg)
end

---@param origin? team.Origin
---@param msg string
function Notes:error(origin, msg)
  self:add(vim.log.levels.ERROR, origin, msg)
end

---@param origin? team.Origin
---@param msg string
function Notes:info(origin, msg)
  self:add(vim.log.levels.INFO, origin, msg)
end

return M
