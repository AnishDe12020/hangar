-- Real bridge, fake pipes with the same overwrite constraint as hs.task.
local n=0
local function check(v,why) assert(v,why); n=n+1 end
local tasks,timers,completed,alerts,encoded={},{},{},{},{}
local failNew,failStart,failWrite,frontPID=false,false,false,nil
local env={hs={configdir='/fixture',json={encode=function(p)
  encoded[p.sequence]=p; return tostring(p.sequence)
end}, application={frontmostApplication=function()
  return frontPID and {pid=function() return frontPID end} or nil
end},alert={show=function(s) alerts[#alerts+1]=s end},printf=function() end,
task={new=function(path,done,stream)
  if failNew then return nil end
  local task={path=path,done=done,stream=stream,writes={},processID=500+#tasks}
  function task:start() return not failStart end
  function task:pid() return self.processID end
  function task:setInput(s)
    if failWrite then error('closed pipe') end
    self.writes[#self.writes+1]=encoded[tonumber(s)]
  end
  function task:terminate() self.terminated=true end
  function task:closeInput() self.closed=true end
  tasks[#tasks+1]=task; return task
end},timer={doAfter=function(sec,fn)
  local t={sec=sec,fn=fn,stop=function(self) self.stopped=true end}
  timers[#timers+1]=t; return t
end}}}
setmetatable(env,{__index=_G})
local M=assert(loadfile(KIT..'/config/picker-panel.lua','t',env))()
local V=M.new(function(row,reason,members) completed[#completed+1]={row=row,reason=reason,members=members} end)
local rows={{id=1,pid=11,text='Aside',workspace='1',partner=2},{id=2,pid=22,text='Ghostty',workspace='1',partner=1}}
local function ack(showing)
  local p=assert(V.inFlight)
  V:receive{action='ack',sequence=p.sequence,session=p.session,showing=showing}
end
local function shown()
  V:receive{action='shown',session=V.session}; frontPID=V.task:pid()
end
local function open(list)
  V:present(list or rows,{},false,0,false,'1')
  if not V.ready then V:receive{action='ready'} end
  shown(); ack(true)
end
local function terminal(packet)
  packet.session=packet.session or V.session
  if packet.hidden==nil then packet.hidden=true end
  V:receive(packet)
  while V.inFlight do ack(false) end
end
check(#tasks==1 and not V.ready)
local startup=V.timeout
V:present(rows,{},false,0,false,'1'); V:step(1); V:confirm()
check(#V.queued==3 and #tasks[1].writes==0)
V:receive{action='ready'}
check(#tasks[1].writes==1 and tasks[1].writes[1].action=='show','only show is written before its ack')
check(V.ready and startup.stopped and V.opening)
frontPID=V.task:pid(); check(not V:ownsKeyboard(),'focus without shown acknowledgement is insufficient')
shown(); check(V:ownsKeyboard() and not V.opening)
frontPID=999; check(not V:ownsKeyboard(),'stale visible flag does not own another app keyboard')
frontPID=V.task:pid()
local pending=V.inFlight
V:receive{action='ack',sequence=pending.sequence+99,session=pending.session,showing=true}
check(#tasks[1].writes==1,'wrong ack does not release the next write')
ack(true); check(#tasks[1].writes==2 and tasks[1].writes[2].action=='step')
ack(true); check(#tasks[1].writes==3 and tasks[1].writes[3].action=='confirm')
V:receive{action='choose',session=V.session-1,id=1,pid=11,ids={1,2}}
check(#completed==0 and V.visible)
terminal{action='choose',id=2,pid=22,ids={1,2}}
check(#completed==1 and completed[1].row.id==2 and not V.visible and not V:ownsKeyboard())
check(#completed[1].members==2 and completed[1].members[1].id==1)
V:receive{action='choose',session=V.session,id=2,pid=22,ids={1,2}}
check(#completed==1,'duplicate terminal packet is ignored')
open(); terminal{action='choose',id=2,pid=999}
check(not completed[#completed].row and not V.visible)
open(); terminal{action='cancel',reason='deactivate'}
check(completed[#completed].reason=='deactivate')
open(); terminal{action='cancel',reason='escape'}
check(completed[#completed].reason=='escape')
open(); V:hide(); local count=#completed; ack(false)
V:receive{action='choose',session=V.session-1,id=1,pid=11,ids={1,2}}
check(#completed==count and not V.opening)
V:shutdown(); check(not V.task and tasks[1].closed and tasks[1].terminated)
V:present(rows,{},false,0,false,'1'); V:hide(); V:receive{action='ready'}
check(#tasks[2].writes==0,'cancelled cold open cannot later flash')
open(); tasks[2].done(1,'','exit')
check(not V.visible and not V.task and #alerts>0)
V:present(rows,{},false,0,false,'1'); tasks[1].done(1,'','stale')
check(V.task==tasks[3])
V.timeout.fn(); check(tasks[3].terminated and not V.visible and not V.task)
failNew=true; V:present(rows,{},false,0,false,'1')
check(not V.visible and not V.task)
failNew=false; failStart=true; V:present(rows,{},false,0,false,'1')
check(not V.visible and not V.task)
failStart=false
open(); terminal{action='choose',id=1,pid=11,ids={1}}
check(not completed[#completed].row,'pair cannot be silently reduced to one member')
open(); terminal{action='choose',id=1,pid=11,ids={1,1}}
check(not completed[#completed].row)
open({rows[1],{id=3,pid=33,text='Other',workspace='2'}})
terminal{action='choose',id=1,pid=11,ids={1,3}}
check(not completed[#completed].row)
open({{id=3,pid=33,text='Solo',workspace='2'}})
terminal{action='choose',id=3,pid=33,ids={3}}
check(completed[#completed].row.id==3 and #completed[#completed].members==1)
open(); V:confirm(); ack(false)
check(not V.visible and completed[#completed].reason=='deactivate','closed acknowledgement repairs a lost terminal event')
open(); V:step(1); local deadline=V.ackTimer; local oldTask=V.task
deadline.fn(); check(not V.visible and not V.task and oldTask.terminated)
open(); deadline.fn(); check(V.visible and V.task~=oldTask,'stale timeout leaves new session alone')
terminal{action='cancel',reason='deactivate'}
V:present(rows,{},false,0,false,'1'); local showDeadline=V.showTimer
ack(true); showDeadline.fn()
check(not V.visible and not V.task,'missing shown event has bounded lifetime')
open(); showDeadline.fn(); check(V.visible)
terminal{action='cancel',reason='deactivate'}
open(); V:step(1); local stale=V.inFlight; oldTask=V.task
local before=#oldTask.writes
V:hide(); V:present(rows,{},false,0,false,'1')
check(#oldTask.writes==before and #V.queued==1,'rapid reopen never overlaps setInput')
ack(false)
check(V.visible and V.opening and #oldTask.writes==before+1 and V.inFlight.action=='show')
V:receive{action='ack',sequence=stale.sequence,session=stale.session,showing=false}
check(V.visible and V.inFlight.action=='show','old session cannot cancel fresh show')
shown(); ack(true); terminal{action='cancel',reason='deactivate'}
open(); failWrite=true; V:step(1); failWrite=false
check(not V.visible and not V.task,'write exceptions release the parent mode')
open(); local restored=0
V:hide(function() restored=restored+1 end)
check(restored==0,'programmatic hide must be acknowledged before origin focus')
ack(false); check(restored==1,'confirmed hide restores origin without a fixed sleep')
open(); V:hide(function() restored=restored+1 end)
V:present(rows,{},false,0,false,'1')
ack(false); check(restored==1,'old hide acknowledgement cannot focus behind a reopened picker')
shown(); ack(true); terminal{action='cancel',reason='deactivate'}
open(); terminal{action='choose',id=1,pid=11,ids={1,2},hidden=false}
check(completed[#completed].row==nil,'unconfirmed native hide never commits focus')
open(); terminal{action='cancel',reason='escape',hidden=false}
check(completed[#completed].reason~='escape','unconfirmed escape cannot restore old focus')

if not V.task then V:start() end
V:receive{action='ready',nativeFocus=true,protocolVersion=2}
check(V:canFocus(),'protocol v2 advertises resident focus capability')
local focusCalls={}
local focus=V:focus({id=7,pid=77,restores={{spaceID=900,pid=88}}},function(...)
  focusCalls[#focusCalls+1]={...}
end)
check(focus:start() and V.inFlight.action=='focus','hidden ready picker dispatches resident focus')
local fp=V.inFlight
V:receive{action='focused',sequence=fp.sequence,session=fp.session,id=7,pid=77,ok=true,nativeMs=12}
ack(false)
check(#focusCalls==1 and focusCalls[1][1]==0 and focusCalls[1][4].nativeMs==12,'focused result completes exactly once after ack')
V:receive{action='focused',sequence=fp.sequence,session=fp.session,id=7,pid=77,ok=true}
check(#focusCalls==1,'duplicate resident result is ignored')
focus=V:focus({id=8,pid=88,restores={}},function(...) focusCalls[#focusCalls+1]={...} end)
check(focus:start(),'second resident focus starts')
fp=V.inFlight; ack(false)
check(#focusCalls==2 and focusCalls[2][1]==1,'ack without focused result fails closed')
focus=V:focus({id=9,pid=99,restores={}},function(...) focusCalls[#focusCalls+1]={...} end)
check(focus:start(),'timeout focus starts')
fp=V.inFlight; oldTask=V.task; V.focusOperation.timer.fn()
check(#focusCalls==3 and focusCalls[3][1]==1 and not V.task and oldTask.terminated,'resident focus timeout reports once and retires its owned process')
V:receive{action='focused',sequence=fp.sequence,session=fp.session,id=9,pid=99,ok=true}
V:receive{action='ack',sequence=fp.sequence,session=fp.session,showing=false}
check(#focusCalls==3 and not V.inFlight,'late timeout result and ack cannot affect a future process')
V:start(); V:receive{action='ready',nativeFocus=true,protocolVersion=2}
V:send{action='warm',windows={}}
focus=V:focus({id=10,pid=100,restores={}},function(...) focusCalls[#focusCalls+1]={...} end)
check(focus:start() and #V.queued==1,'focus queues behind an unacknowledged packet')
focus:terminate(); check(#V.queued==0,'terminating queued focus removes it without killing picker')
ack(false); check(#focusCalls==3 and V.task~=nil,'cancelled queued focus has no stale callback')
V:send{action='warm',windows={}}
focus=V:focus({id=15,pid=150,restores={}},function(...) focusCalls[#focusCalls+1]={...} end)
check(focus:start() and #V.queued==1,'deadline focus queues behind healthy traffic')
V.focusOperation.timer.fn()
check(#focusCalls==4 and #V.queued==0 and V.inFlight.action=='warm','queued focus timeout removes its undispatched packet')
ack(false); check(not V.inFlight,'earlier packet ack cannot dispatch timed-out focus')
focus=V:focus({id=11,pid=110,restores={}},function(...) focusCalls[#focusCalls+1]={...} end)
check(focus:start(),'focus starts before a new presentation')
fp=V.inFlight; oldTask=V.task; V:present(rows,{},false,0,false,'1')
check(oldTask.terminated and V.task~=oldTask and #V.queued==1 and V.queued[1].action=='show','new presentation retires in-flight focus owner and queues show for a fresh picker')
V:receive{action='focused',sequence=fp.sequence,session=fp.session,id=11,pid=110,ok=true}
V:receive{action='ack',sequence=fp.sequence,session=fp.session,showing=false}
check(#focusCalls==4 and not V.inFlight and #V.queued==1,'superseded old-process packets cannot callback or release fresh show')
V:receive{action='ready',nativeFocus=true,protocolVersion=2}
check(V.inFlight.action=='show','fresh picker readiness dispatches the replacement show')
shown(); ack(true); terminal{action='cancel',reason='deactivate'}
focus=V:focus({id=12,pid=120,restores={}},function(...) focusCalls[#focusCalls+1]={...} end)
check(focus:start(),'native failure focus starts')
fp=V.inFlight
V:receive{action='focused',sequence=fp.sequence,session=fp.session,id=12,pid=120,ok=false,error='owner changed'}; ack(false)
check(#focusCalls==5 and focusCalls[5][1]==1 and focusCalls[5][3]=='owner changed','native focus failure is correlated without stopping picker')
focus=V:focus({id=13,pid=130,restores={}},function(...) focusCalls[#focusCalls+1]={...} end)
check(focus:start(),'exit focus starts')
V.task.done(1,'','focus exit')
check(#focusCalls==6 and focusCalls[6][1]==1 and not V.task,'picker exit completes hidden focus once')
V:start(); V:receive{action='ready',nativeFocus=true,protocolVersion=2}
failWrite=true
focus=V:focus({id=14,pid=140,restores={}},function(...) focusCalls[#focusCalls+1]={...} end)
check(not focus:start() and #focusCalls==7 and not V.task,'focus pipe write failure completes operation and resets picker')
failWrite=false
V:shutdown()
print(n..' native panel bridge tests passed')
