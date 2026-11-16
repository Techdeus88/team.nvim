local function trace(s)
  _G.trace = _G.trace or {}
  table.insert(_G.trace, s)
end
trace('require delta')
return {
  setup = function(opts)
    trace('setup delta')
    _G.opts = _G.opts or {}
    _G.opts['delta'] = opts == nil and 'none' or opts
  end,
}
