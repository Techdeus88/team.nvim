local function trace(s)
  _G.trace = _G.trace or {}
  table.insert(_G.trace, s)
end
trace('require libby')
return {
  setup = function(opts)
    trace('setup libby')
    _G.opts = _G.opts or {}
    _G.opts['libby'] = opts == nil and 'none' or opts
  end,
}
