local function trace(s)
  _G.trace = _G.trace or {}
  table.insert(_G.trace, s)
end
trace('plugin eps')
