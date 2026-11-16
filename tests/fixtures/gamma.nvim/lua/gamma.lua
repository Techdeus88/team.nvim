local function trace(s)
  _G.trace = _G.trace or {}
  table.insert(_G.trace, s)
end
trace('require gamma')
return {
  setup = function(opts)
    trace('setup gamma')
    _G.opts = _G.opts or {}
    _G.opts['gamma'] = opts == nil and 'none' or opts
  end,
}
