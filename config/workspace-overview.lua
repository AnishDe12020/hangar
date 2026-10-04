-- On-demand AppKit panel. JSON-lines over local pipes; no server or WebKit.
local R = require('leanmac-runtime')
local links = require('window-links')
local B = {visible=false,busy=false,version=0,session=0,snapshots={},epoch=0}
local windowFormat = '%{window-id} %{app-pid} %{app-name} %{app-bundle-id} %{window-title} %{workspace} %{monitor-name} %{window-parent-container-layout} %{workspace-root-container-layout}'
local spaceFormat = '%{workspace} %{monitor-name} %{workspace-is-visible} %{workspace-is-focused}'
local function tell(message)
  B.message=message
  if B.send then B.send() end
end
local function query(args, done)
  R.run(R.aerospace,args,function(code,out,err)
    if code~=0 then done(nil,err); return end
    local ok,rows=pcall(hs.json.decode,out)
    done(ok and type(rows)=='table' and rows or nil, 'Could not read AeroSpace')
  end,4)
end
function B.snapshot(done)
  query({'list-windows','--all','--format',windowFormat,'--json'},function(raw,err)
    if not raw then done(nil,err); return end
    local displayed={}
    for _,w in ipairs(leanmac.picker.filterNativeTabs(raw)) do displayed[w['window-id']]=true end
    local rows,byID,layoutRows={},{},{}
    for _,w in ipairs(raw) do
      if w['app-name']~='Hammerspoon' and w['app-name']~='leanmac-overview' and w['app-bundle-id']~='local.leanmac.overview'
        and w['app-name']~='leanmac-picker' and w['app-bundle-id']~='local.leanmac.picker' then
        local c={id=w['window-id'],pid=w['app-pid'],app=w['app-name'],bundle=w['app-bundle-id'],
          title=w['window-title'] or '',workspace=tostring(w.workspace),monitor=w['monitor-name'],
          layout=w['window-parent-container-layout'],root=w['workspace-root-container-layout']}
        layoutRows[#layoutRows+1]=c
        if displayed[c.id] then rows[#rows+1]=c; byID[c.id]=c end
      end
    end
    query({'list-workspaces','--all','--format',spaceFormat,'--json'},function(spaces,spaceErr)
      if not spaces then done(nil,spaceErr); return end
      local result={rows=rows,byID=byID,layoutRows=layoutRows,spaces={}}
      for _,ws in ipairs(spaces) do result.spaces[#result.spaces+1]={id=tostring(ws.workspace),
        monitor=ws['monitor-name'],visible=ws['workspace-is-visible'],focused=ws['workspace-is-focused']} end
      table.sort(result.spaces,function(a,b)
        local an,bn=tonumber(a.id),tonumber(b.id)
        if an and bn then return an<bn end
        return a.id<b.id
      end)
      done(result)
    end)
  end)
end
function B.model(snapshot)
  local model={spaces=snapshot.spaces,windows=snapshot.rows,pairs={},version=B.version,session=B.session,busy=B.busy}
  for _,p in ipairs(links.reconcile(snapshot.layoutRows or snapshot.rows)) do
    if snapshot.byID[p.a.id] and snapshot.byID[p.b.id] then
      model.pairs[#model.pairs+1]={ids={p.a.id,p.b.id},workspace=snapshot.byID[p.a.id].workspace}
    end
  end
  return model
end
function B.refresh()
  if not B.visible or B.busy or B.refreshing or leanmac.groups.busy then return end
  B.refreshing=true
  local session,epoch=B.session,B.epoch
  B.snapshot(function(snapshot,err)
    B.refreshing=false
    -- A snapshot captured while a layout operation was in flight can reflect a
    -- transient layout; reconciling pairs against it would corrupt stored
    -- metadata. Settlement already schedules a fresh refresh.
    if not B.visible or session~=B.session or B.busy or leanmac.groups.busy then return end
    if epoch~=B.epoch then B.scheduleRefresh(); return end
    if not snapshot then tell(err or 'AeroSpace is unavailable'); return end
    B.snapshotData=snapshot; B.version=B.version+1
    B.snapshots[B.version]=snapshot; B.snapshots[B.version-24]=nil
    B.currentModel=B.model(snapshot)
    B.send()
  end)
end
function B.scheduleRefresh()
  if not B.visible or B.busy or leanmac.groups.busy then return end
  B.epoch=B.epoch+1
  if B.refreshTimer then B.refreshTimer:stop() end
  B.refreshTimer=hs.timer.doAfter(0.2,function() B.refreshTimer=nil; B.refresh() end)
end
function B.hide(restore)
  B.visible=false
  if B.refreshTimer then B.refreshTimer:stop(); B.refreshTimer=nil end
  if B.busy then B.send() elseif B.task then
    local task=B.task; B.task=nil; B.ready=false; task:closeInput()
  end
  if restore and B.origin then
    local origin=B.origin
    B.snapshot(function(current)
      local latest=current and current.byID[origin.id]
      if latest and latest.pid==origin.pid then
        hs.timer.doAfter(0.12,function() leanmac.groups.focus(latest,function() end) end)
      end
    end)
  end
end
local function checkWindow(row)
  local w=row and hs.window.get(row.id)
  return w and w:pid()==row.pid and w:isStandard() and not w:isFullScreen() and not w:isMinimized()
end
-- Menus carry the exact pair they displayed. A stale menu or drag must not
-- dissolve, move or swap a pair that changed since it was captured.
local function pairMatches(expected, actual)
  if expected == nil then return true end
  if expected == false then return actual == nil end
  return type(expected)=='table' and type(expected.a)=='table' and type(expected.b)=='table'
    and type(actual)=='table' and type(actual.a)=='table' and type(actual.b)=='table'
    and expected.a.id==actual.a.id and expected.a.pid==actual.a.pid
    and expected.b.id==actual.b.id and expected.b.pid==actual.b.pid
end
function B.validate(message, old, fresh)
  if type(message)~='table' or type(message.ids)~='table' or #message.ids<1 or #message.ids>2 then return nil,'Invalid selection' end
  local selected,seen={},{}
  for _,id in ipairs(message.ids) do
    local before=old and old.byID[id]
    local now=fresh.byID[id]
    if type(id)~='number' or seen[id] or not before or not now or before.pid~=now.pid or before.workspace~=now.workspace then
      return nil,'A window changed; refresh and try again'
    end
    selected[#selected+1]=now; seen[id]=true
  end
  if message.action=='move' then
    local found=false
    for _,ws in ipairs(fresh.spaces) do if ws.id==message.target then found=true end end
    if not found then return nil,'That space no longer exists' end
  elseif message.action=='pair' then
    if #selected~=2 or selected[1].workspace~=selected[2].workspace then return nil,'Move both windows into the same space first' end
  elseif message.action=='swap' then
    if #selected~=2 then return nil,'Swap acts on the whole linked pair' end
  elseif message.action~='focus' and message.action~='separate' then return nil,'Unknown action' end
  if #selected==2 and message.action~='pair' then
    local p=links.containing(selected[1].id)
    if not p or not (p.a.id==selected[2].id or p.b.id==selected[2].id) then return nil,'The linked pair changed' end
  end
  if message.pair~=nil and not pairMatches(message.pair, links.containing(selected[1].id)) then
    return nil,'The linked pair changed'
  end
  if type(message.pair)=='table' then
    local pa,pb=message.pair.a,message.pair.b
    local a,b=fresh.byID[pa.id],fresh.byID[pb.id]
    if not a or not b or a.pid~=pa.pid or b.pid~=pb.pid or a.workspace~=b.workspace
      or a.layout~=b.layout or (a.layout~='h_tiles' and a.layout~='h_accordion') then
      return nil,'The linked pair changed'
    end
  end
  return selected
end
local function settled(success,message,origin)
  local task,session=B.task,B.session
  local status=message or (success and 'Layout updated' or 'Could not finish; inspect the current layout')
  local function finish(reopen)
    if B.session~=session then return end
    B.busy=false
    B.epoch=B.epoch+1
    if reopen and B.returnToBoard then B.show(origin) end
    tell(status)
    leanmac.picker.refresh(); B.refresh()
  end
  if not success or not origin or not task or not B.returnToBoard then
    -- Validation errors can stay on an already visible board. A failed hidden
    -- operation must not reactivate its old workspace.
    B.busy=false
    if not B.visible then B.hide(false) end
    finish(false); return
  end
  -- orderOut can remove the panel from AeroSpace's window inventory, while
  -- reactivating that same native panel can return to its old workspace. The
  -- drag/menu is finished: retire only this helper, then create a fresh board
  -- on a verified target. No app windows are moved by this reopening step.
  B.task=nil; B.ready=false; B.visible=false; B.origin=nil
  task:closeInput()
  local function cancelled()
    status=status..' · Overview closed to avoid switching spaces'
    hs.alert.show(status); finish(false)
  end
  local function matches(w)
    return w and w['window-id']==origin.id and w['app-pid']==origin.pid
      and tostring(w.workspace)==origin.workspace and checkWindow(origin)
  end
  local function focusTarget()
    query({'list-windows','--all','--format',windowFormat,'--json'},function(rows)
      if B.session~=session then return end
      local found=false
      for _,w in ipairs(rows or {}) do if matches(w) then found=true end end
      if not found then cancelled(); return end
      R.run(R.aerospace,{'focus','--window-id',tostring(origin.id)},function(code)
        if B.session~=session then return end
        if code~=0 then cancelled(); return end
        query({'list-windows','--focused','--format',windowFormat,'--json'},function(focused)
          if B.session~=session then return end
          if not focused or #focused~=1 or not matches(focused[1]) then cancelled(); return end
          finish(true)
        end)
      end,4)
    end)
  end
  local tries=0
  local function waitForExit()
    if B.session~=session then return end
    if not task:isRunning() then focusTarget(); return end
    tries=tries+1
    if tries>=20 then task:terminate(); cancelled(); return end
    B.operationTimer=hs.timer.doAfter(0.05,waitForExit)
  end
  waitForExit()
end
local function awaitGroups(message,origin)
  local count=0
  local function poll()
    count=count+1
    if not leanmac.groups.busy then
      local success=leanmac.groups.lastResult==true
      settled(success,success and message or (leanmac.groups.lastError or 'Could not finish; inspect the current layout'),origin); return
    end
    if count>=150 then settled(false,'Layout command timed out; no further actions sent'); return end
    B.operationTimer=hs.timer.doAfter(0.1,poll)
  end
  poll()
end
local function formPair(a,b)
  B.hide(false)
  hs.timer.doAfter(0.12,function()
    if leanmac.groups.busy then settled(false,'Another layout action started; try again'); return end
    leanmac.groups.pair(a,b)
    awaitGroups('Linked split ready',a)
  end)
end
local function separate(row, expected)
  B.hide(false)
  hs.timer.doAfter(0.12,function()
    if leanmac.groups.busy then settled(false,'Another layout action started; try again'); return end
    leanmac.groups.separate(row, expected); awaitGroups('Window separated',row)
  end)
end
local function swapPair(a, b, expected)
  B.hide(false)
  hs.timer.doAfter(0.12,function()
    if leanmac.groups.busy then settled(false,'Another layout action started; try again'); return end
    leanmac.groups.swap(a, b, expected); awaitGroups('Pair order swapped',b)
  end)
end
function B.handle(message)
  if type(message)~='table' then return end
  if message.action=='ack' then B.nativeState=message; return end
  if message.action=='pointer' then B.nativePointer=message; return end
  if message.action=='ready' then B.ready=true; B.send(); B.refresh(); return end
  if message.action=='close' and B.visible then B.returnToBoard=false; B.hide(not B.busy); return end
  if not B.visible or message.session~=B.session then return end
  if B.busy or leanmac.groups.busy then tell('Still arranging the previous action'); return end
  if message.action=='refresh' then B.refresh(); return end
  if message.action=='workspace' then
    local found=false
    for _,ws in ipairs(B.snapshotData and B.snapshotData.spaces or {}) do if ws.id==message.target then found=true end end
    if not found then return end
    B.hide(false); R.run(R.aerospace,{'workspace',message.target},function(code,_,err) if code~=0 then hs.alert.show(err) end end)
    return
  end
  -- A title/focus event may refresh the board during a drag. Validate against
  -- the actual displayed snapshot, not a newer snapshot the UI has queued.
  local old=type(message.version)=='number' and B.snapshots[message.version] or nil
  if not old then tell('Selection expired; try that again'); B.refresh(); return end
  B.epoch=B.epoch+1; B.busy=true; B.returnToBoard=true; tell('Arranging…')
  B.snapshot(function(fresh,err)
    if not fresh then settled(false,err); return end
    local selected,problem=B.validate(message,old,fresh)
    if not selected then settled(false,problem); return end
    for _,w in ipairs(selected) do if not checkWindow(w) then settled(false,'Window unavailable or in native fullscreen'); return end end
    if message.action=='focus' then
      B.busy=false; B.hide(false)
      hs.timer.doAfter(0.12,function() leanmac.groups.focus(selected[1],function() end) end)
    elseif message.action=='pair' then
      formPair(selected[1],selected[2])
    elseif message.action=='separate' then
      separate(selected[1], message.pair)
    elseif message.action=='swap' then
      swapPair(selected[1], selected[2], message.pair)
    elseif message.action=='move' then
      if selected[1].workspace==message.target then
        if #selected==1 and links.containing(selected[1].id) then
          separate(selected[1], message.pair)
        else settled(true,'Already in this space') end
        return
      end
      local index,moved=1,{}
      local function nextWindow()
        local w=selected[index]
        if not w then
          if #selected==2 then
            B.snapshot(function(after,afterErr)
              if not after or not after.byID[selected[1].id] or not after.byID[selected[2].id] then settled(false,afterErr); return end
              formPair(after.byID[selected[1].id],after.byID[selected[2].id])
            end)
          else settled(true,'Moved to space '..message.target) end
          return
        end
        R.run(R.aerospace,{'move-node-to-workspace','--window-id',tostring(w.id),message.target},function(code,_,moveErr)
          if code~=0 then
            -- Best-effort rollback of only the windows this operation moved.
            local prior=moved[1]
            if prior then R.run(R.aerospace,{'move-node-to-workspace','--window-id',tostring(prior.id),prior.workspace},function(rollbackCode)
              settled(false,rollbackCode==0 and 'Move failed; first window returned. Re-form the pair if needed.' or 'Move and rollback failed; inspect both spaces.')
            end) else settled(false,moveErr) end
            return
          end
          moved[#moved+1]=w; links.unlink(w.id); index=index+1; nextWindow()
        end)
      end
      nextWindow()
    end
  end)
end
function B.show(origin)
  if B.visible then B.returnToBoard=false; B.hide(true); return end
  if B.busy or leanmac.groups.busy then hs.alert.show('A layout operation is still running'); return end
  local focused=origin and hs.window.get(origin.id) or hs.window.focusedWindow()
  B.origin=origin or (focused and leanmac.picker.byID[focused:id()] or nil)
  B.session=B.session+1; B.visible=true; B.returnToBoard=true; B.message=nil
  local screen=focused and focused:screen() or hs.screen.mainScreen()
  local f=screen:frame(); local width=math.min(1120,f.w-60); local height=math.min(720,f.h-80)
  local buffer,task='',nil
  task=hs.task.new(hs.configdir..'/bin/LeanMacOverview.app/Contents/MacOS/leanmac-overview',function(code,_,err)
    if B.task~=task then return end
    B.task=nil; B.visible=false; B.ready=false
    if code~=0 then hs.alert.show('Overview exited: '..(err or tostring(code))) end
  end,function(_,out)
    if B.task~=task then return false end
    buffer=buffer..(out or '')
    if #buffer>65536 then task:terminate(); return false end
    while buffer:find('\n',1,true) do
      local pos=buffer:find('\n',1,true); local line=buffer:sub(1,pos-1); buffer=buffer:sub(pos+1)
      local ok,message=pcall(hs.json.decode,line)
      if ok then B.handle(message) end
    end
    return true
  end,{tostring(f.x+(f.w-width)/2),tostring(f.y+(f.h-height)/2),tostring(width),tostring(height)})
  B.task=task; B.ready=false
  if not task or not task:start() then B.task=nil; B.visible=false; hs.alert.show('Could not start native overview'); return end
  B.refresh()
end
function B.send()
  if B.task and B.ready then
    B.task:setInput(hs.json.encode({model=B.currentModel,visible=B.visible,busy=B.busy,
      status=B.message or 'Drag windows between spaces · Drop onto a window to pair · Right-click for actions'})..'\n')
  end
end
local previousShutdown=hs.shutdownCallback
hs.shutdownCallback=function()
  if B.task then B.task:terminate() end
  if previousShutdown then previousShutdown() end
end
B.hotkey=hs.hotkey.bind({'alt'},'o',B.show)
assert(B.hotkey and B.hotkey.enabled,'LeanMac overview shortcut could not be registered')
return B
