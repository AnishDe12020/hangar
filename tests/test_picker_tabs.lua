-- Execute with Lua 5.4 (or the bundled LuaSkin runner below). No live app calls.
local object = {}
setmetatable(object, {__index = function() return function(self) return self end end})
local linksEnv = {hs = {settings = {get = function() return {} end, set = function() end}}}
setmetatable(linksEnv, {__index = _G})
local links = assert(loadfile(KIT .. '/config/window-links.lua', 't', linksEnv))()
local env = {hs = {
  fs = {attributes = function() return true end}, configdir = '/fixture',
  chooser = {new = function() return object end},
  eventtap = {new = function() return object end, event = {types = {keyDown=1, flagsChanged=2}}},
  hotkey = {bind = function() return object end},
  task = {new = function() return object end}, timer = {doAfter = function() return object end},
}}
local realRequire = require
env.require = function(name)
  if name == 'window-links' then return links end
  if name == 'picker-panel' then return {new=function() return object end} end
  return realRequire(name)
end
setmetatable(env, {__index = _G})
local P = assert(loadfile(KIT .. '/config/window-picker.lua', 't', env))()
local function row(id, pid, bundle)
  return {['window-id']=id, ['app-pid']=pid or 12, ['app-bundle-id']=bundle or 'com.mitchellh.ghostty',
    ['window-title']='same title', ['workspace-is-visible']=false}
end
local function ids(rows)
  local result = {}; for _, w in ipairs(rows) do result[#result+1] = w['window-id'] end
  return table.concat(result, ',')
end
local tests = 0
local function check(expected, rows, snapshot)
  assert(ids(P.filterNativeTabs(rows, snapshot)) == expected)
  tests = tests + 1
end
local ghostty = {row(3504), row(3505), row(3510)}
check('3510', ghostty, function() return {[3510]=true} end)
assert(table.concat(P.filteredNativeTabIDs, ',') == '3504,3505')
-- Never collapse two actual windows by their app or identical title.
check('3504,3510', ghostty, function() return {[3504]=true, [3510]=true} end)
check('3504,3505,3510', ghostty, function() return {[3504]=true, [3505]=true, [3510]=true} end)
check('3504,3505,3510', ghostty, function() return nil end)
check('3504,3505,3510', ghostty, function() error('AX timed out') end)
check('3504,3505,3510', ghostty, function() return {} end)
check('3504,3505,3510', ghostty, function() return {[9999]=true} end)
check('3504', {row(3504)}, function() error('Single row needs no check') end)
local calls = {}
check('2,4,5,6', {row(1,12),row(2,12),row(3,13),row(4,13),row(5,14,'at.studio.AsideBrowser'),row(6,14,'at.studio.AsideBrowser')},
  function(pid) calls[pid]=(calls[pid] or 0)+1; return pid==12 and {[2]=true} or {[4]=true} end)
assert(calls[12]==1 and calls[13]==1 and calls[14]==nil)
-- Refresh integration: filtered identities populate the list actually shown.
env.hs.json = {decode=function() return ghostty end}
env.hs.image = {imageFromAppBundle=function() return nil end}
env.hs.axuielement = {applicationElementForPID=function()
  return {setTimeout=function(self) return self end, attributeValue=function()
    return {{setTimeout=function(self) return self end, asHSWindow=function() return {id=function() return 3510 end} end}}
  end}
end}
local completion
env.hs.task.new = function(_, callback) completion=callback; return object end
P.refreshTask = nil
P.refresh()
completion(0, 'fixture')
assert(#P.cache==1 and P.cache[1].id==3510 and P.byID[3504]==nil and P.byID[3510]~=nil)
tests = tests + 1
-- Keep the physical association while its native tab is inactive, but do not
-- incorrectly annotate the currently visible Ghostty tab as that pair member.
local aside=row(88,99,'at.studio.AsideBrowser')
local paired={aside,row(3504),row(3510)}
for _,w in ipairs(paired) do
  w.workspace='1'; w['app-name']='Fixture'
  w['window-parent-container-layout']='h_tiles'
  w['workspace-root-container-layout']='v_accordion'
end
links.link({id=88,pid=99},{id=3504,pid=12})
env.hs.json.decode=function() return paired end
P.refreshTask=nil; P.refresh(); completion(0,'fixture')
assert(#links.pairs==1 and links.containing(88).b.id==3504)
assert(P.byID[3504]==nil and P.byID[3510]~=nil and P.byID[88].partner==nil)
tests=tests+2
print(tests .. ' native-tab picker tests passed')
