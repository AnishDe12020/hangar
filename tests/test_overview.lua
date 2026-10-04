local object={enabled=true}
setmetatable(object,{__index=function()return function(self)return self end end})
local fakeWin={}
for id=1,4 do local n=id; fakeWin[n]={id=function() return n end,pid=function() return 100+n end,
  isStandard=function() return true end,isFullScreen=function() return false end,isMinimized=function() return false end} end
local groupCalls={}
local runtime={aerospace='fixture-aerospace'}
local G={busy=false,lastResult=true,lastError=nil,
  pair=function(x,y) groupCalls[#groupCalls+1]={'pair',x.id,y.id} end,
  separate=function(x,e) groupCalls[#groupCalls+1]={'separate',x.id,e} end,
  swap=function(x,y,e) groupCalls[#groupCalls+1]={'swap',x.id,y.id,e} end,
  focus=function(x) groupCalls[#groupCalls+1]={'focus',x.id} end}
local env={hs={settings={get=function()return {}end,set=function()end},
  hotkey={bind=function()return object end},image={imageFromAppBundle=function()return nil end},
  alert={show=function() end},printf=function() end,
  json={decode=function(value) return value end},
  timer={doAfter=function(_,fn) fn(); return {stop=function() end} end},
  window={get=function(id) return fakeWin[id] end}},
  require=function(name) return {} end,
  leanmac={picker={refresh=function() end,filterNativeTabs=function(x) return x end},groups=G}}
setmetatable(env,{__index=_G})
local linkEnv={hs={settings={get=function()return {}end,set=function()end}}}
setmetatable(linkEnv,{__index=_G})
local L=assert(loadfile(KIT..'/config/window-links.lua','t',linkEnv))()
env.require=function(name) if name=='window-links' then return L end; return runtime end
local B=assert(loadfile(KIT..'/config/workspace-overview.lua','t',env))()
local tests=0
local function check(value)assert(value,'check at line '..debug.getinfo(2,'l').currentline);tests=tests+1 end
local function row(id,workspace,layout,root)
  return {id=id,pid=100+id,app='App',bundle='fixture.app',workspace=workspace or '1',
    layout=layout or 'h_tiles',root=root or 'h_tiles'}
end
local a,b,c,d=row(1),row(2),row(3),row(4)
check(#L.reconcile({a,b})==1)
check(L.containing(1).b.id==2)
L.unlink(1);check(#L.pairs==0)
check(#L.reconcile({a,b,c,d})==0) -- matching layouts are not group identities
L.link(a,b);L.link(b,c);check(#L.pairs==1 and L.containing(1)==nil)
check(#L.reconcile({a,b,c,d})==1)
local changed=row(2);changed.pid=999
check(#L.reconcile({a,changed,c,d})==0)
L.link(a,b);check(#L.reconcile({a,row(2,'2'),c,d})==0)
L.link(a,b);check(#L.reconcile({a,row(2,'1','floating'),c,d})==0)
L.link(a,b);check(#L.reconcile({row(1,'1','v_accordion','v_accordion'),row(2,'1','v_accordion','v_accordion')})==0)
check(#L.reconcile({a,row(2,'1','h_tiles','v_accordion')})==0) -- no bootstrap of unknown nested groups
local function snapshot(rows)
  local s={rows=rows,byID={},spaces={{id='1'},{id='2'}}}
  for _,w in ipairs(rows)do s.byID[w.id]=w end
  return s
end
local old=snapshot({a,b,c,d})
local function valid(message,fresh)return B.validate(message,old,fresh or old)~=nil end
check(valid({action='move',ids={1},target='2'}))
check(not valid({action='move',ids={1},target='99'}))
check(not valid({action='move',ids={1,1},target='2'}))
check(not valid({action='move',ids={1,2,3},target='2'}))
check(not valid({action='move',ids={'1'},target='2'}))
check(not valid({action='move',ids={999},target='2'}))
check(not valid({action='shell',ids={1},target='2'}))
check(not valid({action='pair',ids={1,2}},snapshot({a,row(2,'2')})))
check(not valid({action='focus',ids={1}},snapshot({row(1,'2')})))
local stale=row(1);stale.pid=999
check(not valid({action='focus',ids={1}},snapshot({stale})))
check(valid({action='pair',ids={1,2}}))
check(not valid({action='move',ids={1,2},target='2'}))
L.link(a,b);check(valid({action='move',ids={1,2},target='2'}))
local model=B.model(snapshot({a,b,c,d}))
check(#model.pairs==1 and #model.windows==4 and #model.spaces==2)
-- A native tab absent from the visible UI is not absent from AeroSpace's tree.
local hiddenTab=snapshot({a,c,d}); hiddenTab.layoutRows={a,b,c,d}
model=B.model(hiddenTab)
check(#model.pairs==0 and #L.pairs==1 and L.containing(a.id).b.id==b.id)
model=B.model(snapshot({a,b,c,d}))
check(#model.pairs==1)
-- Filtering must not bootstrap a two-window pair from three physical leaves.
L.pairs={}; hiddenTab=snapshot({a,b}); hiddenTab.layoutRows={a,b,c}
check(#B.model(hiddenTab).pairs==0 and #L.pairs==0)
-- Swap and pair-identity validation.
L.pairs={}
check(not valid({action='swap',ids={1,2}}))
L.link(a,b)
check(valid({action='swap',ids={1,2},pair={a={id=1,pid=101},b={id=2,pid=102}}}))
check(not valid({action='swap',ids={1}}))
check(not valid({action='swap',ids={1,3}}))
check(not valid({action='swap',ids={1,2},pair={a={id=1,pid=101},b={id=3,pid=103}}}))
check(valid({action='separate',ids={1},pair={a={id=1,pid=101},b={id=2,pid=102}}}))
check(valid({action='separate',ids={2},pair={a={id=1,pid=101},b={id=2,pid=102}}}))
check(not valid({action='separate',ids={2},pair={a={id=2,pid=102},b={id=9,pid=109}}}))
check(not valid({action='separate',ids={3},pair={a={id=1,pid=101},b={id=2,pid=102}}}))
check(valid({action='move',ids={1},target='2',pair={a={id=1,pid=101},b={id=2,pid=102}}}))
check(not valid({action='move',ids={1},target='2',pair={a={id=1,pid=101},b={id=4,pid=104}}}))
-- Controller paths: header swap acts on the whole pair in displayed order.
local captured=nil
B.snapshot=function(done) captured=done end
B.session=7; B.visible=true; B.busy=false; B.returnToBoard=true
B.snapshots={}; B.snapshots[4]=old
groupCalls={}
B.handle({action='swap',ids={1,2},session=7,version=4,pair={a={id=1,pid=101},b={id=2,pid=102}}})
check(B.busy and captured~=nil)
captured(old)
local last=groupCalls[#groupCalls]
check(last[1]=='swap' and last[2]==1 and last[3]==2 and last[4].b.id==2)
check(B.message=='Pair order swapped' and not B.busy)
-- Member separate sends its own id plus the captured pair identity.
B.visible=true; B.busy=false; B.returnToBoard=true
B.handle({action='separate',ids={2},session=7,version=4,pair={a={id=1,pid=101},b={id=2,pid=102}}})
captured(old)
last=groupCalls[#groupCalls]
check(last[1]=='separate' and last[2]==2 and last[3].a.id==1 and last[3].b.id==2)
check(B.message=='Window separated')
-- Header separate takes the first member of the same captured pair.
B.visible=true; B.busy=false; B.returnToBoard=true
B.handle({action='separate',ids={1},session=7,version=4,pair={a={id=1,pid=101},b={id=2,pid=102}}})
captured(old)
last=groupCalls[#groupCalls]
check(last[1]=='separate' and last[2]==1)
-- A menu opened against a pair that has since changed must not dissolve it.
B.visible=true; B.busy=false; B.returnToBoard=true
local n=#groupCalls
B.handle({action='separate',ids={1},session=7,version=4,pair={a={id=1,pid=101},b={id=9,pid=109}}})
captured(old)
check(#groupCalls==n and B.message=='The linked pair changed' and #L.pairs==1)
B.handle({action='swap',ids={1,2},session=7,version=4,pair={a={id=2,pid=102},b={id=1,pid=101}}})
captured(old)
check(#groupCalls==n and B.message=='The linked pair changed' and L.pairs[1].a.id==1)
-- A drag payload's captured pair is validated before same-space separation.
B.visible=true; B.busy=false; B.returnToBoard=true
B.handle({action='move',ids={1},target='1',session=7,version=4,pair={a={id=1,pid=101},b={id=9,pid=109}}})
captured(old)
check(#groupCalls==n and B.message=='The linked pair changed')
B.visible=true; B.busy=false; B.returnToBoard=true
B.handle({action='move',ids={1},target='1',session=7,version=4,pair={a={id=1,pid=101},b={id=2,pid=102}}})
captured(old)
last=groupCalls[#groupCalls]
check(last[1]=='separate' and last[2]==1 and last[3].b.id==2)
-- Snapshot capture: an unknown displayed version expires instead of guessing.
B.visible=true; B.busy=false; B.returnToBoard=true
B.refreshing=false
B.handle({action='separate',ids={1},session=7,version=99})
check(B.message=='Selection expired; try that again')
B.refreshing=false
-- An in-flight refresh finishing while an operation runs is discarded, and a
-- settled operation invalidates any snapshot captured before it finished.
L.pairs={}; L.link(a,b)
B.version=10; B.epoch=0; B.currentModel=nil; B.refreshing=false; B.busy=false; B.visible=true
B.refresh()
check(B.refreshing==true)
B.busy=true
captured(old)
check(B.refreshing==false and B.version==10 and B.currentModel==nil)
B.busy=false; B.epoch=B.epoch+1
B.refresh()
captured(old)
check(B.version==11 and B.currentModel~=nil and #B.currentModel.pairs==1)
B.refresh()
check(B.refreshing==true)
B.epoch=B.epoch+1
captured(old)
check(B.version==11)
G.busy=true; captured(old); B.refresh()
check(not B.refreshing)
G.busy=false; local e=B.epoch; B.busy=true; B.scheduleRefresh(); check(B.epoch==e)
B.busy=false; B.scheduleRefresh(); check(B.epoch==e+1 and B.refreshing==true)
captured(old)
check(B.version==12)
L.link(a,b)
check(not valid({action='move',ids={1},target='1',pair=false}))
check(not valid({action='separate',ids={1},pair={a={id=1,pid=101},b={id=2,pid=102}}},snapshot({a,row(2,'2'),c,d})))
-- A completed action retires the old panel instead of re-keying it in space 2.
local function panelAction(action,options)
  options=options or {}
  local commands,closed,opened,terminated={},0,0,0
  local task={closeInput=function() closed=closed+1 end,isRunning=function() return options.hung or false end,
    terminate=function() terminated=terminated+1 end}
  B.session=7
  B.task=task; B.ready=false; B.visible=true; B.busy=false; B.returnToBoard=true; B.refreshing=false
  B.origin=row(4,'2'); G.lastResult=not options.failed
  B.show=function(origin)
    opened=opened+1; B.visible=true; B.origin=origin; B.session=B.session+1
    B.task={closeInput=function() end}
  end
  runtime.run=function(_,args,done)
    commands[#commands+1]=args
    if args[1]=='list-windows' then
      local rows={{['window-id']=1,['app-pid']=options.stale and 901 or 101,workspace='1'},
        {['window-id']=2,['app-pid']=102,workspace='1'}}
      if args[2]=='--focused' then
        rows={rows[action=='swap' and 2 or 1]}
        if options.focusChanged then rows[1].workspace='2' end
      end
      done(options.queryFails and 1 or 0,rows)
    elseif args[1]=='focus' then
      done(options.focusFails and 1 or 0)
    else error('Unexpected overview command: '..args[1]) end
  end
  L.pairs={}; L.link(a,b)
  B.handle({action=action,ids=action=='separate' and {1} or {1,2},session=7,version=4})
  captured(old)
  return commands,closed,opened,terminated
end
local commands,closed,opened,terminated=panelAction('pair')
check(#commands==3 and commands[2][1]=='focus' and commands[2][3]=='1' and closed==1 and opened==1)
check(B.visible and not B.busy and B.origin.id==1 and B.origin.workspace=='1')
B.hide(true); captured(old)
check(groupCalls[#groupCalls][1]=='focus' and groupCalls[#groupCalls][2]==1)
commands,closed,opened=panelAction('swap')
check(B.visible and B.origin.id==2 and closed==1 and opened==1)
commands,closed,opened=panelAction('separate')
check(B.visible and B.origin.id==1 and closed==1 and opened==1)
for _,options in ipairs({{stale=true},{focusFails=true},{focusChanged=true},{queryFails=true}}) do
  commands,closed,opened=panelAction('pair',options)
  check(not B.visible and not B.busy and B.origin==nil and closed==1 and opened==0)
  if options.stale or options.queryFails then check(#commands==1) end
end
commands,closed,opened,terminated=panelAction('pair',{hung=true})
check(not B.busy and B.task==nil and #commands==0 and closed==1 and opened==0 and terminated==1)
commands,closed,opened=panelAction('pair',{failed=true})
check(not B.visible and not B.busy and #commands==0 and closed==1 and opened==0)
print(tests..' overview model and action-safety tests passed')
