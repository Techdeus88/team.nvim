local function trace(s)
  _G.trace = _G.trace or {}
  table.insert(_G.trace, s)
end
trace('require beta')
return {
  setup = function(opts)
    trace('setup beta')
    _G.opts = _G.opts or {}
    _G.opts['beta'] = opts == nil and 'none' or opts
  end,
}
