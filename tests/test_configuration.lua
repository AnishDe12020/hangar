local calls={}
local env={hs={hotkey={bind=function(mods,key,fn)
  calls[#calls+1]={mods=mods,key=key,callback=fn};return {enabled=true}
end}}, require=function() return {apps={terminal='Custom App'}, hotkeys={overview={mods={'ctrl','alt'},key='u'}}} end}
setmetatable(env,{__index=_G})
local C=assert(loadfile(KIT..'/config/hangar-config.lua','t',env))()
local invoked=false
C.bind('overview',function() invoked=true end)
assert(calls[1].key=='u' and table.concat(calls[1].mods,',')=='ctrl,alt')
calls[1].callback();assert(invoked and C.apps.terminal=='Custom App')
assert(C.label('overview')=='⌃⌥U')
env.hs.hotkey.bind=function() return nil end
local ok,err=pcall(function() C.bind('overview',function() end) end)
assert(not ok and err:find('Could not register Hangar shortcut: overview',1,true))
print('4 configured shortcut checks passed')
