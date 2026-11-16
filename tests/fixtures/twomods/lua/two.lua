local function trace(s)
  _G.trace = _G.trace or {}
  table.insert(_G.trace, s)
end
trace('require two')
return {
  setup = function(opts)
    trace('setup two')
    _G.opts = _G.opts or {}
    _G.opts['two'] = opts == nil and 'none' or opts
  end,
}
