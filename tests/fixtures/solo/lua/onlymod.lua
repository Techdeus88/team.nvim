local function trace(s)
  _G.trace = _G.trace or {}
  table.insert(_G.trace, s)
end
trace('require onlymod')
return {
  setup = function(opts)
    trace('setup onlymod')
    _G.opts = _G.opts or {}
    _G.opts['onlymod'] = opts == nil and 'none' or opts
  end,
}
