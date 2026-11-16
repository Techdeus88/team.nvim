local function trace(s)
  _G.trace = _G.trace or {}
  table.insert(_G.trace, s)
end
trace('require dashed')
return {
  setup = function(opts)
    trace('setup dashed')
    _G.opts = _G.opts or {}
    _G.opts['dashed'] = opts == nil and 'none' or opts
  end,
}
