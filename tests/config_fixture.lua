-- Test fixtures load the same shared helper with generated default data.
function HANGAR_TEST_CONFIGURE(env)
  local previous = env.require or require
  local helperEnv = {hs=env.hs, require=function(name)
    assert(name=='hangar-settings'); return {
      apps=HANGAR_TEST_SETTINGS.apps, hotkeys=HANGAR_TEST_SETTINGS.hotkeys}
  end}
  setmetatable(helperEnv,{__index=_G})
  local helper=assert(loadfile(KIT..'/config/hangar-config.lua','t',helperEnv))()
  env.require=function(name) if name=='hangar-config' then return helper end; return previous(name) end
end
