local function trace(s)
  _G.trace = _G.trace or {}
  table.insert(_G.trace, s)
end
trace('require one')
return {
  setup = function(opts)
    trace('setup one')
    _G.opts = _G.opts or {}
    _G.opts['one'] = opts == nil and 'none' or opts
  end,
}
