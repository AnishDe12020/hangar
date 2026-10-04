-- Persistent AppKit presentation over local pipes. No web runtime or window scans.
local M = {}
function M.new(done)
  local V = {visible=false, opening=false, ready=false, nativeFocus=false, session=0, sequence=0, queued={}, byID={}}
  local executable = hs.configdir .. '/bin/LeanMacPicker.app/Contents/MacOS/leanmac-picker'
  function V:endPresentation()
    self.visible=false; self.opening=false; self.shownSession=nil; self.queued={}
    if self.showTimer then self.showTimer:stop(); self.showTimer=nil end
  end
  function V:finishFocus(op, code, err, result, suppress)
    if not op or op.finished then return end
    op.finished=true
    if op.timer then op.timer:stop(); op.timer=nil end
    if self.focusOperation==op then self.focusOperation=nil end
    if not suppress and not op.cancelled then op.callback(code,'',err or '',result) end
  end
  function V:fail(message)
    local visible=self.visible
    self:finishFocus(self.focusOperation,1,message)
    self:shutdown()
    if visible then done(nil); hs.alert.show(message) end
  end
  function V:ownsKeyboard()
    if not self.visible or self.opening or self.shownSession~=self.session or not self.task then return false end
    local app=hs.application.frontmostApplication()
    return app~=nil and app:pid()==self.task:pid()
  end
  function V:pump()
    if not self.ready or not self.task or self.inFlight or #self.queued==0 then return end
    local packet=table.remove(self.queued,1)
    self.inFlight=packet
    -- hs.task:setInput replaces unsent bytes: never issue another write until
    -- the native process acknowledges consuming this complete packet.
    local ok=pcall(function() self.task:setInput(hs.json.encode(packet)..'\n') end)
    if not ok then self:fail('Window panel connection failed'); return end
    self.ackTimer=hs.timer.doAfter(packet.action=='focus' and 3 or 2,function()
      if self.inFlight==packet then self:fail('Window panel stopped responding; retry Option+Tab') end
    end)
  end
  function V:send(packet)
    self.sequence=self.sequence+1
    packet.session=self.session; packet.sequence=self.sequence
    self.queued[#self.queued+1]=packet
    self:pump()
    return packet.sequence
  end
  function V:receive(packet)
    if packet.action == 'ready' then
      self.ready = true
      self.nativeFocus = packet.nativeFocus==true and type(packet.protocolVersion)=='number' and packet.protocolVersion>=2
      if self.timeout then self.timeout:stop(); self.timeout=nil end
      self:pump()
      return
    end
    if packet.action=='focused' then
      local op=self.focusOperation
      if not op or op.finished or packet.sequence~=op.sequence or packet.session~=op.session
          or packet.id~=op.id or packet.pid~=op.pid then return end
      op.result=packet
      return
    end
    if packet.action=='ack' then
      local pending=self.inFlight
      if not pending or packet.sequence~=pending.sequence or packet.session~=pending.session then return end
      self.inFlight=nil
      if self.ackTimer then self.ackTimer:stop(); self.ackTimer=nil end
      if pending.action=='focus' then
        local op=self.focusOperation
        if op and op.sequence==pending.sequence and op.session==pending.session then
          local result=op.result
          if result and result.ok==true then self:finishFocus(op,0,'',result)
          else self:finishFocus(op,1,result and result.error or 'Native focus returned no result',result) end
        end
      end
      local hidden=self.hideCompletion
      if hidden and packet.sequence==hidden.sequence and packet.session==hidden.session then
        self.hideCompletion=nil
        if packet.showing==false and self.session==hidden.nextSession then hidden.done() end
      end
      if self.visible and packet.session==self.session and packet.showing==false
          and (pending.action=='show' or not self.opening) then
        self:endPresentation(); done(nil,'deactivate')
      end
      self:pump(); return
    end
    if packet.session ~= self.session or not self.visible then return end
    if packet.action == 'shown' then
      self.lastShownMs=packet.elapsedMs; self.lastState=packet
      self.opening=false; self.shownSession=self.session
      if self.showTimer then self.showTimer:stop(); self.showTimer=nil end
    end
    if packet.action == 'selection' then self.selectedID=packet.id; self.lastState=packet end
    if packet.action == 'choose' then
      local row=self.byID[packet.id]
      local ids, members, seen = packet.ids, {}, {}
      local valid = packet.hidden==true and row and row.pid == packet.pid and type(ids)=='table' and (#ids==1 or #ids==2)
      if valid then
        for _,id in ipairs(ids) do
          local member=self.byID[id]
          if not member or seen[id] or member.workspace~=row.workspace then valid=false; break end
          seen[id]=true; members[#members+1]=member
        end
        valid=valid and seen[row.id]
        if valid and #members==2 then
          valid=members[1].partner==members[2].id and members[2].partner==members[1].id
        elseif valid then
          valid=not row.partner or not self.byID[row.partner]
        end
      end
      if valid then
        self:endPresentation(); done(row, nil, members)
      else
        self:hide(); done(nil)
      end
    elseif packet.action == 'cancel' then
      if packet.hidden==true then
        self:endPresentation(); done(nil, packet.reason)
      else self:hide(); done(nil,'deactivate') end
    end
  end
  function V:start()
    if self.task then return true end
    self.ready=false
    local buffer, task = '', nil
    task=hs.task.new(executable, function(code, _, err)
      if self.task ~= task then return end
      self.task=nil; self.ready=false; self.queued={}; self.inFlight=nil
      self.nativeFocus=false
      local op=self.focusOperation; self.focusOperation=nil
      self:finishFocus(op,1,err or 'Native picker exited')
      self.hideCompletion=nil
      if self.ackTimer then self.ackTimer:stop(); self.ackTimer=nil end
      if self.timeout then self.timeout:stop(); self.timeout=nil end
      if self.visible then
        self:endPresentation(); done(nil)
        hs.alert.show('Window panel unavailable; retry Option+Tab')
      end
      if code ~= 0 then hs.printf('LeanMac picker: %s', err or '') end
    end, function(_, out)
      if self.task ~= task then return false end
      buffer=buffer .. (out or '')
      if #buffer > 1000000 then self:fail('Window panel response overflow'); return false end
      while true do
        local i=buffer:find('\n',1,true)
        if not i then break end
        local line=buffer:sub(1,i-1); buffer=buffer:sub(i+1)
        local ok,p=pcall(hs.json.decode,line)
        if ok and type(p)=='table' then
          local handled=pcall(self.receive,self,p)
          if not handled then self:fail('Window panel response failed'); return false end
        end
      end
      return true
    end, {})
    self.task=task
    if not task or not task:start() then
      self.task=nil; self.queued={}
      if self.visible then self:endPresentation(); done(nil) end
      hs.alert.show('Native picker is missing. Run leanmac install.')
      return false
    end
    self.timeout=hs.timer.doAfter(3,function()
      self.timeout=nil
      if self.task==task and not self.ready then self:fail('Window panel did not start; retry Option+Tab') end
    end)
    return true
  end
  local function serialize(choices)
    local rows={}
    for _,c in ipairs(choices) do
      if c.id and c.pid then
        rows[#rows+1]={id=c.id,pid=c.pid,title=c.text,app=c.app,bundle=c.bundle,
          workspace=c.workspace,monitor=c.monitor,visible=c.visible,partner=c.partner,pairSlot=c.pairSlot}
      end
    end
    return rows
  end
  function V:prewarm(choices)
    if not self.task or self.visible then return end
    self:send{action='warm',windows=serialize(choices)}
  end
  function V:present(choices, frame, hold, step, loading, originWorkspace)
    if self.showTimer then self.showTimer:stop() end
    self.hideCompletion=nil
    if self.focusOperation then self.focusOperation.handle:terminate() end
    self.session=self.session+1; self.visible=true; self.opening=true; self.shownSession=nil; self.selectedID=nil; self.byID={}
    for _,c in ipairs(choices) do self.byID[c.id]=c end
    -- Drop obsolete opens/keystrokes if startup was slow or a previous open cancelled.
    self.queued={}
    if not self:start() then return end
    local session=self.session
    self.showTimer=hs.timer.doAfter(3,function()
      if self.visible and self.session==session and self.opening then self:fail('Window panel did not open; retry Option+Tab') end
    end)
    self:send{action='show',windows=serialize(choices),frame=frame,hold=hold,
      step=hold and step or 0,loading=loading,originWorkspace=originWorkspace}
  end
  function V:step(delta) if self.visible then self:send{action='step',delta=delta} end end
  function V:navigate(axis,delta) if self.visible then self:send{action='navigate',axis=axis,delta=delta} end end
  function V:confirm() if self.visible then self:send{action='confirm'} end end
  function V:hide(onHidden)
    local visible=self.visible
    self.hideCompletion=nil
    self:endPresentation()
    if visible and self.ready and self.task then
      local request={session=self.session,sequence=self.sequence+1,nextSession=self.session+1,done=onHidden}
      if onHidden then self.hideCompletion=request end
      self:send{action='hide'}
    elseif onHidden then onHidden() end
    self.session=self.session+1
  end
  function V:canFocus() return self.ready and self.nativeFocus and self.task~=nil end
  function V:focus(args, callback)
    local op={callback=callback,id=args.id,pid=args.pid,session=args.session or self.session,finished=false,started=false}
    local handle={}
    op.handle=handle
    function handle:start()
      if op.started or op.finished or V.visible or not V:canFocus()
          or type(op.id)~='number' or op.id%1~=0 or op.id<1
          or type(op.pid)~='number' or op.pid%1~=0 or op.pid<1
          or type(args.restores)~='table' then return false end
      for _,r in ipairs(args.restores) do
        if type(r)~='table' or type(r.spaceID)~='number' or r.spaceID%1~=0 or r.spaceID<1
            or type(r.pid)~='number' or r.pid%1~=0 or r.pid<1 then return false end
      end
      if V.focusOperation then V.focusOperation.handle:terminate() end
      op.started=true; V.focusOperation=op
      op.sequence=V:send{action='focus',id=op.id,pid=op.pid,restores=args.restores}
      op.session=V.session
      if op.finished or V.focusOperation~=op then return false end
      op.timer=hs.timer.doAfter(2,function()
        if V.focusOperation==op then
          for i=#V.queued,1,-1 do if V.queued[i].sequence==op.sequence then table.remove(V.queued,i) end end
          V:finishFocus(op,1,'Native focus timed out')
          if V.inFlight and V.inFlight.action=='focus' and V.inFlight.sequence==op.sequence then
            if V.ackTimer then V.ackTimer:stop(); V.ackTimer=nil end
            V.inFlight=nil
            V:shutdown()
          end
        end
      end)
      return true
    end
    function handle:terminate()
      if op.finished then return end
      local dispatched=V.inFlight and V.inFlight.action=='focus' and V.inFlight.sequence==op.sequence
      op.cancelled=true; op.finished=true
      if op.timer then op.timer:stop(); op.timer=nil end
      if V.focusOperation==op then V.focusOperation=nil end
      for i=#V.queued,1,-1 do if V.queued[i].sequence==op.sequence then table.remove(V.queued,i) end end
      if dispatched then
        if V.ackTimer then V.ackTimer:stop(); V.ackTimer=nil end
        V.inFlight=nil
        V:shutdown()
      end
    end
    return handle
  end
  function V:shutdown()
    self.hideCompletion=nil
    self:endPresentation(); self.inFlight=nil
    if self.ackTimer then self.ackTimer:stop(); self.ackTimer=nil end
    if self.timeout then self.timeout:stop(); self.timeout=nil end
    local task=self.task; self.task=nil; self.ready=false
    self.nativeFocus=false
    if self.focusOperation then self.focusOperation.handle:terminate() end
    if task then task:closeInput(); task:terminate() end
  end
  V:start()
  return V
end
return M
