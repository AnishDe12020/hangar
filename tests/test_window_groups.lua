-- Source-contract tests for exact-leaf pair construction and recovery.
local object = {enabled=true}
setmetatable(object, {__index=function() return function(self) return self end end})
local calls, rows, roots, order, focused, helperCalls, decodedRows = {}, {}, {}, {}, 1, 0, {}
local failMutation, mutationNumber, hook, failRule, queryHook, helperFailure = nil, 0, nil, nil, nil, false
local ordered={}
local views, focusedWorkspace, workspaceCalls, workspaceReadFailure, singleMonitor
local function workspaceRows()
  local result, names = {}, {['1']=true,['2']=true,['3']=true,['4']=true}
  for _, value in pairs(views) do names[value]=true end
  for _, r in ipairs(rows) do names[r.workspace]=true end
  for name in pairs(names) do
    local monitor = singleMonitor and 1 or ((name=='1' or name=='2') and 1 or 2)
    result[#result+1]={workspace=name,['monitor-id']=monitor,['monitor-name']='screen'..monitor,
      ['workspace-is-visible']=views[monitor]==name,['workspace-is-focused']=focusedWorkspace==name}
  end
  return result
end
local function mkWindow(n)
  return {id=function() return n end, pid=function() return 100+n end,
    isStandard=function() return true end, isFullScreen=function() return false end,
    isMinimized=function() return false end, raise=function() focused=n end,
    screen=function() return 'screen-'..n end}
end
local windows = {}; for id=1,8 do windows[id]=mkWindow(id) end
local linkEnv={hs={settings={get=function() return {} end,set=function() end}}}
setmetatable(linkEnv,{__index=_G})
local L=assert(loadfile(KIT..'/config/window-links.lua','t',linkEnv))()
local R={aerospace='/fixture/aerospace'}
local function copyRows(filter)
  local result={}
  for _,r in ipairs(rows) do
    if not filter or r.workspace==filter then
      result[#result+1]={['window-id']=r['window-id'],['app-pid']=r['app-pid'],workspace=r.workspace,
        ['window-parent-container-layout']=r['window-parent-container-layout'],
        ['workspace-root-container-layout']=roots[r.workspace] or r['workspace-root-container-layout']}
    end
  end
  return result
end
local function find(id)
  for _,r in ipairs(rows) do if r['window-id']==id then return r end end
end
local function removeOrder(workspace,id)
  local nextOrder={}
  for _,value in ipairs(order[workspace] or {}) do if value~=id then nextOrder[#nextOrder+1]=value end end
  order[workspace]=nextOrder
end
local function appendOrder(workspace,id)
  order[workspace]=order[workspace] or {}; order[workspace][#order[workspace]+1]=id
end
local function mutate(args)
  local op=args[1]
  if op=='move-node-to-workspace' then
    local id=tonumber(args[3]); local destination=args[4]; local r=find(id); assert(r)
    removeOrder(r.workspace,id); r.workspace=destination; r.group=nil
    roots[destination]=roots[destination] or 'v_accordion'
    r['window-parent-container-layout']=roots[destination]
    appendOrder(destination,id)
  elseif op=='layout' and args[#args]=='tiling' then
    local r=find(tonumber(args[3])); r['window-parent-container-layout']=roots[r.workspace] or 'v_accordion'
  elseif op=='layout' and args[4]=='--root' then
    local r=find(tonumber(args[3])); roots[r.workspace]=args[5]
    for _,other in ipairs(rows) do
      if other.workspace==r.workspace and not other.group then other['window-parent-container-layout']=args[5] end
    end
  elseif op=='layout' and (args[4]=='h_tiles' or args[4]=='h_accordion') then
    local r=find(tonumber(args[3]))
    for _,other in ipairs(rows) do if other.group==r.group then other['window-parent-container-layout']=args[4] end end
  elseif op=='move' then
    local r=find(tonumber(args[3])); assert(args[4]=='--boundaries' and args[5]=='workspace' and args[6]=='down')
    roots[r.workspace]='v_accordion'; r.group=nil; r['window-parent-container-layout']='v_accordion'
    for _,other in ipairs(rows) do
      if other.workspace==r.workspace and not other.group then other['window-parent-container-layout']='v_accordion' end
    end
  elseif op=='join-with' then
    local id=tonumber(args[3]); assert(args[4]=='up'); local r=find(id); local list=order[r.workspace]
    assert(list[#list]==id and #list>=2, 'joined leaf was not destination-root append-last')
    local prior=find(list[#list-1]); local group='pair-'..prior['window-id']..'-'..id
    prior.group=group; r.group=group
    prior['window-parent-container-layout']='h_tiles'; r['window-parent-container-layout']='h_tiles'
  elseif op=='fullscreen' then
    assert(args[2]=='--window-id' and args[4]=='off')
  else
    error('unhandled fixture mutation: '..table.concat(args,' '))
  end
end
function R.run(command,args,done)
  calls[#calls+1]={command=command,args=args}
  if command:find('leanmac%-window%-focus') then
    helperCalls=helperCalls+1
    if helperFailure then done(1,'','focus fixture failure') else focused=tonumber(args[2]); done(0,'','') end
    return
  end
  if args[1]=='list-windows' then
    if queryHook then queryHook(args) end
    local workspace=nil
    for i,value in ipairs(args) do if value=='--workspace' then workspace=args[i+1] end end
    decodedRows=copyRows(workspace)
    if args[2]=='--focused' then
      local selected={}; for _, r in ipairs(decodedRows) do if r['window-id']==focused then selected[1]=r end end
      decodedRows=selected
    end
    done(0,'fixture',''); return
  elseif args[1]=='list-workspaces' then
    if workspaceReadFailure then done(1,'fixture','workspace read failed'); return end
    decodedRows=workspaceRows(); done(0,'fixture',''); return
  elseif args[1]=='workspace' then
    local ws=args[2]; workspaceCalls[#workspaceCalls+1]=ws
    local monitor=singleMonitor and 1 or ((ws=='1' or ws=='2') and 1 or 2)
    views[monitor]=ws; focusedWorkspace=ws; done(0,'',''); return
  elseif args[1]=='focus' then
    focused=tonumber(args[3]); focusedWorkspace=find(focused).workspace; done(0,'',''); return
  end
  mutationNumber=mutationNumber+1
  if hook then hook(mutationNumber,args) end
  if failMutation==mutationNumber or (failRule and failRule(args,mutationNumber)) then
    failMutation=nil; done(1,'','fixture failure'); return
  end
  mutate(args); done(0,'fixture','')
end
local board={refreshes=0}
local lastAlert=nil
local env={hs={
  configdir='/fixture', alert={show=function(s) lastAlert=s end}, printf=function() end,
  chooser={new=function() return object end}, hotkey={bind=function() return object end},
  timer={doAfter=function(_,fn) fn(); return object end, absoluteTime=function() return 123456789 end},
  window={get=function(id) return windows[id] end, focusedWindow=function() return windows[focused] end,
    orderedWindows=function() return ordered end}, spaces={activeSpaceOnScreen=function(screen) return 'space-'..screen end},
  json={decode=function() return decodedRows end},
}, require=function(name)
  if name=='window-links' then return L end
  return R
end, leanmac={picker={byID={},cache={},refresh=function() end},
  overview={scheduleRefresh=function() board.refreshes=board.refreshes+1 end}}}
setmetatable(env,{__index=_G})
HANGAR_TEST_CONFIGURE(env)
local G=assert(loadfile(KIT..'/config/window-groups.lua','t',env))()
local a={id=1,pid=101,workspace='1',monitor='main'}
local b={id=2,pid=102,workspace='1',monitor='main'}
local function row(id,ws,layout,group)
  return {['window-id']=id,['app-pid']=100+id,workspace=ws or '1',group=group,
    ['window-parent-container-layout']=layout or 'v_accordion',
    ['workspace-root-container-layout']='v_accordion'}
end
local function reset(layout)
  calls={}; rows={row(1,'1',layout),row(2,'1',layout)}; roots={['1']=layout or 'v_accordion'}
  order={['1']={1,2}}; G.busy=false; G.lastResult=nil; G.lastError=nil; focused=1; helperCalls=0
  decodedRows={}; L.pairs={}; board.refreshes=0; lastAlert=nil; failMutation=nil; mutationNumber=0
  hook=nil; failRule=nil; queryHook=nil; helperFailure=false; ordered={}; env.leanmac.picker.byID={}
  views={[1]='1',[2]='3'}; focusedWorkspace='1'; workspaceCalls={}; workspaceReadFailure=false; singleMonitor=false
  for id=1,8 do windows[id]=mkWindow(id) end
end
local function mutationCalls()
  local result={}
  for _,call in ipairs(calls) do
    if call.command==R.aerospace and call.args[1]~='list-windows' and call.args[1]~='list-workspaces'
      and call.args[1]~='focus' then result[#result+1]=table.concat(call.args,' ') end
  end
  return result
end
local function scratchRows()
  local result={}; for _,r in ipairs(rows) do if r.workspace:match('^LMPAIR%d+$') then result[#result+1]=r end end
  return result
end
local function bothHome() return find(1).workspace=='1' and find(2).workspace=='1' and #scratchRows()==0 end
local tests=0
local function check(value,message) assert(value,message); tests=tests+1 end

check(G.validatePair(a,b,{[1]=row(1),[2]=row(2)}))
check(not G.validatePair(a,a,{[1]=row(1)}))
local wrong=row(2,'2'); check(not G.validatePair(a,b,{[1]=row(1),[2]=wrong}))
wrong=row(2); wrong['app-pid']=999; check(not G.validatePair(a,b,{[1]=row(1),[2]=wrong}))
local choices=G.candidates(a,{{id=1,text='Aside',workspace='1'},{id=2,text='Ghostty',workspace='1'},
  {id=3,text='Aside',workspace='2'},{id=4,text='Aside',workspace='1'}})
check(#choices==2 and choices[1].id==4 and choices[2].id==2)

-- Both chosen leaves are rebuilt at the destination root. An unrelated nested
-- pair remains grouped; no flatten/focus-dependent eval is part of the contract.
reset(); rows[#rows+1]=row(3,'1','h_accordion','keep'); rows[#rows+1]=row(4,'1','h_accordion','keep')
order['1']={1,3,4,2}; G.pair(a,b)
local commands=mutationCalls(); local all=table.concat(commands,'\n')
check(G.lastResult==true and not G.busy and bothHome())
check(find(1).group==find(2).group and find(3).group=='keep' and find(4).group=='keep')
check(commands[1]:match('move%-node%-to%-workspace %-%-window%-id 1 LMPAIR%d+'))
check(commands[2]:match('move%-node%-to%-workspace %-%-window%-id 2 LMPAIR%d+'))
check(all:find('move%-node%-to%-workspace %-%-window%-id 1 1') and all:find('move%-node%-to%-workspace %-%-window%-id 2 1'))
check(all:find('join%-with %-%-window%-id 2 up') and not all:find('flatten') and not all:find('eval'))
check(helperCalls==1 and focused==1 and L.containing(1).b.id==2)

-- A horizontal destination root is recovered through a workspace-bounded down
-- move, which preserves an unrelated nested subtree as a subtree.
reset('h_tiles'); rows[#rows+1]=row(3,'1','h_accordion','keep'); rows[#rows+1]=row(4,'1','h_accordion','keep')
order['1']={3,4,1,2}; G.pair(a,b); all=table.concat(mutationCalls(),'\n')
check(G.lastResult==true and roots['1']=='v_accordion')
check(all:find('move %-%-window%-id 1 %-%-boundaries workspace down'))
check(find(3).group=='keep' and find(4).group=='keep')

-- Pairing does not depend on the overview restoring focus before mutations.
reset(); focused=3; G.pair(a,b)
check(G.lastResult==true and helperCalls==1 and focused==1)
reset(); focused=3; ordered={windows[4]}; env.leanmac.picker.byID[4]={visible=true,monitor='other'}
G.pair(a,b); local helperArgs
for _, call in ipairs(calls) do if call.command:find('leanmac%-window%-focus') then helperArgs=call.args end end
check(G.lastResult==true and helperArgs[3]=='space-screen-4' and helperArgs[4]=='104')
reset(); helperFailure=true; G.pair(a,b)
check(G.lastResult==true and not G.busy and L.containing(1).b.id==2 and (lastAlert or ''):find('focus unavailable'))

-- Invalid workspace/PID snapshots and pre-busy operations do not mutate.
reset(); find(2).workspace='2'; order['2']={2}; G.pair(a,b)
check(G.lastResult==false and #mutationCalls()==0 and not G.busy)
reset(); find(2)['app-pid']=999; G.pair(a,b)
check(G.lastResult==false and #mutationCalls()==0 and not G.busy)
reset(); G.busy=true; G.pair(a,b)
check(#calls==0)
-- An inactive/replaced native tab stops normal mutation, but raw matching leaves
-- already in scratch are still returned without requiring AX visibility.
reset(); hook=function(n) if n==1 then windows[2]=nil end end; G.pair(a,b)
check(G.lastResult==false and bothHome() and not G.busy)
reset(); hook=function(n) if n==7 then windows[2]=nil end end; G.pair(a,b)
check(G.lastResult==false and bothHome() and not G.busy)

-- A stale pair-bearing menu and a changed pair are rejected before the scratch.
reset(); L.link(a,b)
G.pair(a,b,nil,{a={id=1,pid=101},b={id=9,pid=109}})
check(G.lastResult==false and #mutationCalls()==0 and L.containing(1).b.id==2)
reset(); L.link(a,{id=3,pid=103,workspace='1'}); G.swap(a,b)
check(G.lastResult==false and #mutationCalls()==0 and L.containing(1).b.id==3)

-- Swap rebuilds reversed order and restores a stacked pair layout.
reset(); find(1).group='old'; find(2).group='old'; find(1)['window-parent-container-layout']='h_accordion'
find(2)['window-parent-container-layout']='h_accordion'; L.link(a,b); G.swap(a,b)
all=table.concat(mutationCalls(),'\n')
check(G.lastResult==true and L.pairs[1].a.id==2 and L.pairs[1].b.id==1)
check(find(1).group==find(2).group and find(1)['window-parent-container-layout']=='h_accordion')
check(all:find('join%-with %-%-window%-id 1 up') and all:find('layout %-%-window%-id 2 h_accordion'))

-- A linked window is always physically extracted, even when matching layout
-- strings could describe a nested/root pair. The other leaf is not moved.
reset('h_accordion'); find(1).group='old'; find(2).group='old'; L.link(a,b); G.separate(a)
all=table.concat(mutationCalls(),'\n')
check(G.lastResult==true and #L.pairs==0 and find(1).group==nil and find(2).workspace=='1')
check(all:match('move%-node%-to%-workspace %-%-window%-id 1 LMPAIR%d+') and not all:find('%-%-window%-id 2'))
check(all:find('move %-%-window%-id 1 %-%-boundaries workspace down') and #scratchRows()==0)

-- Every pair-construction hop can fail after partially applying. Recovery only
-- returns matching selected leaves that remain in its own scratch workspace.
reset(); G.pair(a,b); local successfulHops=mutationNumber
for failing=1,successfulHops do
  reset(); failMutation=failing; G.pair(a,b)
  check(G.lastResult==false and not G.busy and bothHome(), 'recovery failed at hop '..failing)
  check((G.lastError or ''):find('may be separated')~=nil, 'failure was reported as clean success')
end

-- If a selected leaf is moved elsewhere or its ID is recycled during failure,
-- recovery leaves it alone rather than touching the new owner/location.
reset(); failMutation=4; hook=function(n)
  if n==4 then
    local scratch=find(1).workspace; removeOrder(scratch,1); find(1).workspace='9'; appendOrder('9',1)
  end
end
G.pair(a,b)
check(G.lastResult==false and find(1).workspace=='9' and find(2).workspace=='1' and not G.busy)
reset(); failMutation=4; hook=function(n) if n==4 then find(1)['app-pid']=999 end end
G.pair(a,b)
check(G.lastResult==false and find(1)['app-pid']==999 and find(2).workspace=='1' and not G.busy)

-- A leaf can move after the first recovery snapshot but before its fresh guard.
-- It is skipped, while the other matching survivor is still returned.
reset(); local recoveryQueries=0; failMutation=4
hook=function(n)
  if n==4 then
    queryHook=function()
      recoveryQueries=recoveryQueries+1
      if recoveryQueries==2 then
        local scratch=find(1).workspace; removeOrder(scratch,1); find(1).workspace='9'; appendOrder('9',1)
      end
    end
  end
end
G.pair(a,b)
check(G.lastResult==false and find(1).workspace=='9' and find(2).workspace=='1' and not G.busy)

-- Permanently failing recovery remains bounded and advertises the scratch that
-- needs inspection instead of leaking the busy flag or looping forever.
reset(); failMutation=4
failRule=function(args) return args[1]=='move-node-to-workspace' and args[4]=='1' end
G.pair(a,b)
check(G.lastResult==false and not G.busy and (G.lastError or ''):find('recovery incomplete in LMPAIR'))

-- Expected pair identity is rechecked immediately before join and once more
-- before metadata replacement, not merely at operation start.
reset(); find(1).group='old'; find(2).group='old'; find(1)['window-parent-container-layout']='h_tiles'
find(2)['window-parent-container-layout']='h_tiles'; L.link(a,b)
hook=function(n) if n==7 then L.link(a,{id=3,pid=103,workspace='1'}) end end
G.swap(a,b)
check(G.lastResult==false and bothHome() and L.containing(1).b.id==3)
reset(); find(1).group='old'; find(2).group='old'; find(1)['window-parent-container-layout']='h_tiles'
find(2)['window-parent-container-layout']='h_tiles'; L.link(a,b)
hook=function(n) if n==8 then L.link(a,{id=3,pid=103,workspace='1'}) end end
G.swap(a,b)
check(G.lastResult==false and bothHome() and L.containing(1).b.id==3)

-- Separate also returns the exact leaf on failure and retains pair metadata.
reset(); find(1).group='old'; find(2).group='old'; L.link(a,b); failMutation=2; G.separate(a)
check(G.lastResult==false and find(1).workspace=='1' and #scratchRows()==0 and #L.pairs==1 and not G.busy)
reset('h_tiles'); find(1).group='old'; find(2).group='old'; L.link(a,b)
local expectedPair={a={id=1,pid=101},b={id=2,pid=102}}
hook=function(n) if n==5 then L.link(a,{id=3,pid=103,workspace='1'}) end end
G.separate(a,expectedPair)
check(G.lastResult==false and find(1).workspace=='1' and L.containing(1).b.id==3 and not G.busy)

-- Empty scratch workspaces remain alive while visible on a different display.
-- Restore that display and preserve the real workspace that had global focus.
reset(); hook=function(_,args)
  if args[1]=='join-with' then views[2]=G.lastScratch end
end
G.pair(a,b)
check(G.lastResult==true and G.lastWorkspaceCleanup==true and views[2]=='3')
check(table.concat(workspaceCalls,',')=='3,1' and focusedWorkspace=='1')
-- A real user-selected workspace must not be overwritten with the old snapshot.
reset(); hook=function(_,args) if args[1]=='join-with' then views[2]='4' end end
G.pair(a,b)
check(G.lastResult==true and views[2]=='4' and #workspaceCalls==0)
-- Same-monitor, single-display scratch visibility is also restored.
reset(); singleMonitor=true; views={[1]='1'}
hook=function(_,args) if args[1]=='join-with' then views[1]=G.lastScratch;focusedWorkspace=G.lastScratch end end
G.pair(a,b)
check(G.lastResult==true and views[1]=='1' and #workspaceCalls==1)
-- Failure recovery must dismiss an empty scratch too, not just successful pairs.
reset(); failMutation=4
hook=function(n) if n==4 then views[2]=G.lastScratch end end
G.pair(a,b)
check(G.lastResult==false and bothHome() and views[2]=='3' and G.lastWorkspaceCleanup==true)
-- No workspace snapshot: stop before any selected window is moved.
reset(); workspaceReadFailure=true; G.pair(a,b)
check(G.lastResult==false and #mutationCalls()==0 and bothHome())
print(tests..' window-group contract tests passed')
