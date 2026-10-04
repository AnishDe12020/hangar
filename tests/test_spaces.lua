-- Gathering native Desktop windows must be deliberate; loading is read-only.
local moves, reloads, prompts, preferenceWrites = 0, 0, 0, 0
local answer, action = 'Cancel', nil
local screen = {getUUID = function() return 'display-fixture' end}
local env = {hs = {
  fs = {attributes = function() return true end},
  execute = function() preferenceWrites = preferenceWrites + 1 end,
  task = {new = function() return {start=function() reloads=reloads+1 end} end},
  screen = {allScreens=function() return {screen} end, mainScreen=function() return screen end},
  spaces = {
    allSpaces=function() return {['display-fixture']={1,2}} end,
    spaceType=function() return 'user' end,
    activeSpaceOnScreen=function() return 1 end,
    windowsForSpace=function() return {42} end,
    moveWindowToSpace=function(id, destination)
      assert(id==42 and destination==1); moves=moves+1
    end,
  },
  dialog = {blockAlert=function() prompts=prompts+1; return answer end},
  alert = {show=function() end},
  hotkey = {bind=function(_,_,callback) action=callback; return {enabled=true} end},
}}
setmetatable(env, {__index=_G})
HANGAR_TEST_CONFIGURE(env)
local S=assert(loadfile(KIT .. '/config/spaces-sync.lua', 't', env))()
assert(preferenceWrites==0 and moves==0 and reloads==0, 'module load must not change preferences or windows')
action()
assert(prompts==1 and moves==0 and reloads==0, 'cancel must leave windows untouched')
answer='Gather'; action()
assert(prompts==2 and moves==1 and reloads==1, 'confirmed hotkey gathers')
answer='Cancel'; S.collapseNow()
assert(prompts==3 and moves==1, 'palette and hotkey share confirmation')
print('4 native Desktop consent checks passed')
