local U = require('hangar-config')
-- Cached exact-window switcher with a native AppKit presentation.
local P = {active = false, generation = 0}
local cli = hs.fs.attributes('/opt/homebrew/bin/aerospace') and '/opt/homebrew/bin/aerospace' or '/usr/local/bin/aerospace'
local exactFocus = hs.configdir .. '/bin/leanmac-window-focus'
local links = require('window-links')
local function stop()
  P.active = false
  P.loading = false
  if P.events then P.events:stop() end
end
local function cancelFocus()
  P.focusGeneration = (P.focusGeneration or 0) + 1
  if P.focusTimer then P.focusTimer:stop(); P.focusTimer = nil end
  if P.focusTask then P.focusTask:terminate(); P.focusTask = nil end
  if P.focusValidationTimer then P.focusValidationTimer:stop(); P.focusValidationTimer=nil end
end
-- Resolve only the owning app, once per selected ID for this commit. Retain
-- these AX objects through the helper callback; never rescan every app by ID.
local function windowMatches(window, row)
  local ok, matches = pcall(function()
    local ax=window and hs.axuielement.windowElement(window)
    return ax and ax:isValid()==true and window:id() == row.id and window:pid() == row.pid
  end)
  return ok and matches
end
local function windowResolver()
  local resolved = {}
  return function(row)
    if not row or type(row.id) ~= 'number' or type(row.pid) ~= 'number' then return nil end
    local window = resolved[row.id]
    if window then return windowMatches(window, row) and window or nil end
    local ok, found = pcall(function()
      local app = hs.application.applicationForPID(row.pid)
      return app and app:getWindow(row.id)
    end)
    if ok and windowMatches(found, row) then resolved[row.id] = found; return found end
  end
end
local function otherMonitorFronts(choice, resolve)
  local args, seen = {}, {}
  if #hs.screen.allScreens() < 2 then return args end
  -- CG ordering has no system-wide Accessibility scan. Resolve only a cached,
  -- on-screen candidate on each other display, checking both CG and AX owners.
  local ok, windows = pcall(hs.window.list, false)
  if not ok or type(windows) ~= 'table' then return nil end
  for _, window in ipairs(windows) do
    local cached = P.byID and P.byID[window.kCGWindowNumber]
    if cached and cached.visible and cached.pid == window.kCGWindowOwnerPID
      and window.kCGWindowIsOnscreen and cached.monitor ~= choice.monitor and not seen[cached.monitor] then
      local live = resolve(cached)
      if live then
        local screen = live:screen()
        local space = screen and hs.spaces.activeSpaceOnScreen(screen)
        if space then
          table.insert(args, tostring(space)); table.insert(args, tostring(cached.pid))
          seen[cached.monitor] = true
        end
      end
    end
  end
  return args
end
function P.validateGroup(members, raw)
  if type(raw)~='table' or #members~=2 then return false end
  local byID={}
  for _,w in ipairs(raw) do
    if type(w)~='table' or type(w['window-id'])~='number' then return false end
    byID[w['window-id']]=w
  end
  local a,b=byID[members[1].id],byID[members[2].id]
  return a~=nil and b~=nil and a['app-pid']==members[1].pid and b['app-pid']==members[2].pid
    and a.workspace~=nil and b.workspace~=nil
    and tostring(a.workspace)==members[1].workspace and tostring(b.workspace)==members[2].workspace
    and members[1].workspace==members[2].workspace
    and a['window-parent-container-layout']==b['window-parent-container-layout']
    and (a['window-parent-container-layout']=='h_tiles' or a['window-parent-container-layout']=='h_accordion')
end
local function focus(choice, members)
  cancelFocus()
  local began = hs.timer.absoluteTime()
  local generation, id = P.focusGeneration, choice.id
  local isGroup = members and #members == 2
  local selected = isGroup and members or {choice}
  local useExactFocus = hs.fs.attributes(exactFocus, 'mode') == 'file' and choice.pid ~= nil
  local resolve, live = windowResolver(), {}
  local metric = {requested=id, workspace=choice.workspace, monitor=choice.monitor, exact=useExactFocus==true}
  P.lastFocus = metric
  if isGroup then metric.members = {members[1].id, members[2].id} end
  local function elapsed(since) return (hs.timer.absoluteTime() - since) / 1000000 end
  local function reject(message)
    metric.success=false; metric.totalMs=elapsed(began)
    hs.alert.show(message)
  end
  local function launch()
    if generation ~= P.focusGeneration then return end
    local prepared = hs.timer.absoluteTime()
    if useExactFocus or isGroup then
      for _, member in ipairs(selected) do
        live[member.id] = resolve(member)
        if not live[member.id] then reject(isGroup and 'Group changed; reopen picker' or 'Window unavailable'); return end
      end
    end
    local command, args = cli, {'focus', '--window-id', tostring(id)}
    local restorePackets={}
    if useExactFocus then
      command, args = exactFocus, {tostring(choice.pid), tostring(id)}
      local restores = otherMonitorFronts(choice, resolve)
      if not restores then reject('Cannot verify other display focus; retry picker'); return end
      for index=1,#restores,2 do
        table.insert(args,restores[index]); table.insert(args,restores[index+1])
        restorePackets[#restorePackets+1]={spaceID=tonumber(restores[index]),pid=tonumber(restores[index+1])}
      end
    end
    metric.prepareMs=elapsed(prepared)
    local helperBegan = hs.timer.absoluteTime()
    local task
    local function focused(code, _, err, nativeResult)
      if generation ~= P.focusGeneration or P.focusTask ~= task then return end
      P.focusTask=nil
      metric.helperMs=elapsed(helperBegan)
      if nativeResult then metric.nativeMs=nativeResult.nativeMs end
      if code ~= 0 then reject('Window unavailable'); hs.printf('Window picker: %s', err); return end
      local raiseBegan=hs.timer.absoluteTime()
      if useExactFocus or isGroup then
        local recheckBegan=hs.timer.absoluteTime()
        -- Recheck retained exact objects before raising either member. A closed
        -- or recycled window must not cause partial or app-wide activation.
        for _, member in ipairs(selected) do
          if not windowMatches(live[member.id], member) then
            reject(isGroup and 'Group changed; reopen picker' or 'Window unavailable'); return
          end
        end
        metric.identityRecheckMs=elapsed(recheckBegan)
        local axRaiseBegan=hs.timer.absoluteTime()
        if isGroup then
          for _, member in ipairs(selected) do if member.id ~= id then live[member.id]:raise() end end
        end
        live[id]:raise()
        metric.axRaiseMs=elapsed(axRaiseBegan)
      end
      metric.raiseMs=elapsed(raiseBegan); metric.totalMs=elapsed(began); metric.success=true
    end
    if useExactFocus and P.panel.canFocus and P.panel:canFocus() then
      metric.transport='resident'
      task=P.panel:focus({id=id,pid=choice.pid,restores=restorePackets},focused)
    else
      metric.transport='process'
      task = hs.task.new(command, focused, args)
    end
    P.focusTask=task
    if not task then reject('Window focus unavailable'); return end
    if not task:start() and P.focusTask==task then P.focusTask=nil; reject('Window focus unavailable') end
  end
  -- Native choose/escape is emitted only AFTER orderOut. Programmatic cancel
  -- below waits for the hide acknowledgement. Neither needs an arbitrary sleep.
  if not isGroup then launch(); return end
  if not P.pairPartner or P.pairPartner[members[1].id] ~= members[2].id then
    reject('Group changed; reopen picker'); return
  end
  local validationBegan=hs.timer.absoluteTime()
  local task
  task=hs.task.new(cli,function(code,out)
    if generation ~= P.focusGeneration or P.focusTask ~= task then return end
    P.focusTask=nil
    if P.focusValidationTimer then P.focusValidationTimer:stop(); P.focusValidationTimer=nil end
    metric.validationMs=elapsed(validationBegan)
    local ok,raw=pcall(hs.json.decode,out)
    if code~=0 or not ok or not P.validateGroup(members,raw) then reject('Group changed; reopen picker'); return end
    launch()
  end,{'list-windows','--all','--format',
    '%{window-id} %{app-pid} %{workspace} %{window-parent-container-layout}','--json'})
  P.focusTask=task
  if not task or not task:start() then P.focusTask=nil; reject('Cannot check group'); return end
  P.focusValidationTimer=hs.timer.doAfter(2,function()
    if P.focusTask==task then task:terminate(); P.focusTask=nil; reject('Group check timed out') end
    P.focusValidationTimer=nil
  end)
end
P.panel = require('picker-panel').new(function(choice, reason, members)
  stop()
  if choice then focus(choice, members) end
  if not choice and reason == 'escape' and P.originChoice then focus(P.originChoice) end
end)
function P.dismiss()
  cancelFocus()
  P.generation = P.generation + 1
  stop()
  P.panel:hide()
end
function P.cancel()
  local restore = P.active and P.originChoice
  cancelFocus()
  local generation=P.focusGeneration
  P.generation=P.generation+1; stop()
  P.panel:hide(function()
    if restore and generation==P.focusGeneration then focus(restore) end
  end)
end
function P.step(delta)
  if P.loading then P.steps = P.steps + delta; return end
  P.panel:step(delta)
end
function P.confirm()
  if not P.active then return end
  if P.loading then P.acceptAfterLoad = true; return end
  P.panel:confirm()
end
P.events = hs.eventtap.new({hs.eventtap.event.types.keyDown, hs.eventtap.event.types.flagsChanged}, function(e)
  if not P.active then return false end
  local ownsKeyboard=P.panel:ownsKeyboard()
  if not ownsKeyboard and not P.panel.opening then P.dismiss(); return false end
  local flags = e:getFlags()
  if e:getType() == hs.eventtap.event.types.flagsChanged then
    if P.holdMode and not flags.alt then P.confirm() end
    return false
  end
  local key = e:getKeyCode()
  -- Plain keys belong exclusively to AppKit's local window monitor. Even a
  -- stale session can never swallow Return, Tab or Escape in another app.
  if ownsKeyboard and flags.alt then
    local navigation = {[123]={'horizontal',-1},[124]={'horizontal',1},[125]={'vertical',1},[126]={'vertical',-1}}
    local nav = navigation[key]
    if nav then P.panel:navigate(nav[1],nav[2]); return true end
  end
  return false
end)
P.cache, P.recency, P.sequence = {}, {}, 0
P.icons = {}
local function iconFor(bundle)
  if not bundle or bundle == '' then return nil end
  local cached = P.icons[bundle]
  if cached ~= nil then return cached or nil end
  local img = hs.image.imageFromAppBundle(bundle)
  if img then img = img:setSize({w = 32, h = 32}) end
  P.icons[bundle] = img or false
  return img
end
local function noteFocus(id)
  P.pendingFocusID = id
  if id and P.byID and P.byID[id] then
    P.currentID = id
    P.sequence = P.sequence + 1
    P.recency[id] = P.sequence
  end
end
local function displayChoices()
  local choices = {}
  for _, c in ipairs(P.cache) do table.insert(choices, c) end
  table.sort(choices, function(a, b)
    if a.id == b.id then return false end
    if a.id == P.originID then return true end
    if b.id == P.originID then return false end
    local function rank(c)
      if c.workspace == P.originWorkspace then return 0 end
      return c.visible and 1 or 2
    end
    local ag, bg = rank(a), rank(b)
    if ag ~= bg then return ag < bg end
    if a.workspace ~= b.workspace then
      local an, bn = tonumber(a.workspace), tonumber(b.workspace)
      if an and bn then return an < bn end
      return a.workspace < b.workspace
    end
    local ar, br = P.recency[a.id] or 0, P.recency[b.id] or 0
    if ar ~= br then return ar > br end
    if a.text ~= b.text then return a.text < b.text end
    return a.id < b.id
  end)
  P.choices = choices
end
local function present()
  P.panel:present(P.choices or {}, P.screenFrame, P.holdMode, P.steps,
    P.loading, P.originWorkspace)
end

local function ghosttyWindowIDs(pid)
  -- Native tabs retain CGWindow IDs, but AXWindows contains the actual top-level
  -- windows. Read this once per Ghostty process, only during background refresh.
  local app = hs.axuielement.applicationElementForPID(pid)
  if not app or not app:setTimeout(0.08) then return nil end
  local windows = app:attributeValue('AXWindows')
  if type(windows) ~= 'table' or #windows == 0 then return nil end
  local ids = {}
  for _, element in ipairs(windows) do
    if not element:setTimeout(0.08) then return nil end
    local window = element:asHSWindow()
    local id = window and window:id()
    if not id then return nil end -- An incomplete AX response is not evidence to hide a window.
    ids[id] = true
  end
  return ids
end

function P.filterNativeTabs(windows, snapshot)
  snapshot = snapshot or ghosttyWindowIDs
  local groups, live = {}, {}
  for _, w in ipairs(windows) do
    if w['app-bundle-id'] == 'com.mitchellh.ghostty' and w['app-pid'] then
      local pid = w['app-pid']
      groups[pid] = groups[pid] or {}
      table.insert(groups[pid], w)
    end
  end
  for pid, group in pairs(groups) do
    if #group > 1 then
      local ok, ids = pcall(snapshot, pid)
      if ok and type(ids) == 'table' then
        -- During a tab switch the two APIs may describe different instants.
        -- Only prune when they agree on at least one real window; otherwise
        -- keep AeroSpace's rows until the next event/refresh resolves the race.
        for _, w in ipairs(group) do
          if ids[w['window-id']] then live[pid] = ids; break end
        end
      end
    end
  end
  local filtered, removed = {}, {}
  for _, w in ipairs(windows) do
    local ids = w['app-bundle-id'] == 'com.mitchellh.ghostty' and live[w['app-pid']]
    if ids and not ids[w['window-id']] then
      table.insert(removed, w['window-id'])
    else
      table.insert(filtered, w)
    end
  end
  P.filteredNativeTabIDs = removed
  return filtered
end

function P.refresh()
  -- An event arriving during an in-flight list coalesces into one follow-up;
  -- that snapshot may predate the event, so dropping it left the cache stale.
  if P.stopping then return end
  local groups = leanmac and leanmac.groups
  if groups and groups.busy then P.refreshQueued = true; return end
  if P.refreshTask then P.refreshQueued = true; return end
  P.refreshQueued = false
  local layoutEpoch = groups and groups.layoutEpoch
  local function failed(message)
    if P.refreshTimeout then P.refreshTimeout:stop(); P.refreshTimeout = nil end
    P.refreshTask = nil
    if P.active and P.loading then P.cancel(); hs.alert.show(message) end
    if P.refreshQueued and not P.stopping then P.refresh() end
  end
  local task
  task = hs.task.new(cli, function(code, out)
    if task ~= P.refreshTask then return end -- late completion of a timed-out task
    if P.refreshTimeout then P.refreshTimeout:stop(); P.refreshTimeout = nil end
    P.refreshTask = nil
    local currentGroups = leanmac and leanmac.groups
    if currentGroups and (currentGroups.busy or currentGroups.layoutEpoch ~= layoutEpoch) then
      P.refreshQueued = true
      if not currentGroups.busy then P.refresh() end
      return
    end
    local ok, windows = pcall(hs.json.decode, out)
    if code ~= 0 or not ok or type(windows) ~= 'table' then
      if P.active and P.loading then P.cancel(); hs.alert.show('AeroSpace is unavailable') end
    else
      -- Native-tab filtering controls presentation, not AeroSpace membership.
      -- A hidden tab can still own a real leaf in a split; forgetting that link
      -- here leaves the physical split behind with no way to identify it.
      local displayed = {}
      for _, w in ipairs(P.filterNativeTabs(windows)) do displayed[w['window-id']] = true end
      local cache, byID, linkRows, linkByID, monitors = {}, {}, {}, {}, {}
      local monitorCount, layoutComplete = 0, true
      for _, w in ipairs(windows) do
        if w['app-name'] ~= 'Hammerspoon' and w['app-name'] ~= 'leanmac-overview' and w['app-bundle-id'] ~= 'local.leanmac.overview'
          and w['app-name'] ~= 'leanmac-picker' and w['app-bundle-id'] ~= 'local.leanmac.picker' then
          local workspaceKnown = (type(w.workspace) == 'string' and w.workspace:match('%S') ~= nil)
            or type(w.workspace) == 'number'
          local ws = workspaceKnown and tostring(w.workspace) or '?'
          if w['workspace-is-focused'] then P.focusedWorkspace = ws end
          local layout = w['window-parent-container-layout']
          local root = w['workspace-root-container-layout']
          if type(w['window-id']) ~= 'number' or type(w['app-pid']) ~= 'number'
            or not workspaceKnown or type(layout) ~= 'string' or type(root) ~= 'string' then
            layoutComplete = false
          end
          local linkRow = {id=w['window-id'], pid=w['app-pid'], workspace=ws,
            workspaceKnown=workspaceKnown, layout=layout, root=root}
          linkRows[#linkRows + 1] = linkRow
          if linkRow.id ~= nil then linkByID[linkRow.id] = linkRow end
          local monitor = w['monitor-name']
          if monitor and not monitors[monitor] then
            monitors[monitor] = true; monitorCount = monitorCount + 1
          end
          local title, app = w['window-title'], w['app-name']
          local c = {text=(type(title) == 'string' and title ~= '' and title) or app or '?',
            app=app, title=(type(title) == 'string' and title) or '',
            id=w['window-id'], workspace=ws, bundle=w['app-bundle-id'], monitor=monitor,
            pid=w['app-pid'], visible=w['workspace-is-visible'] == true,
            image=iconFor(w['app-bundle-id'])}
          if displayed[c.id] then
            table.insert(cache, c)
            if c.id ~= nil then byID[c.id] = c end
          end
        end
      end
      -- Reconcile shared split-pair links only on a complete enough snapshot:
      -- a partial or field-poor response must not rewrite stored pair data.
      local linked = (#linkRows > 0 and layoutComplete) and links.reconcile(linkRows) or links.pairs
      -- Stored or reconciled pairs annotate only when both members are
      -- confirmed by their own live rows: numeric id/pid, a real matching
      -- workspace, and a known compatible horizontal parent layout. A member
      -- that floated, moved, or lost its fields is not annotated until then.
      local partner, pairSlot = {}, {}
      for _, pair in ipairs(linked or {}) do
        local a = type(pair) == 'table' and pair.a or nil
        local b = type(pair) == 'table' and pair.b or nil
        local ra = type(a) == 'table' and a.id ~= nil and linkByID[a.id] or nil
        local rb = type(b) == 'table' and b.id ~= nil and linkByID[b.id] or nil
        local ca = ra and byID[a.id] or nil
        local cb = rb and byID[b.id] or nil
        if ra and rb and ca and cb
          and type(ra.id) == 'number' and type(ra.pid) == 'number'
          and type(rb.id) == 'number' and type(rb.pid) == 'number'
          and type(a.pid) == 'number' and ca.pid == a.pid
          and type(b.pid) == 'number' and cb.pid == b.pid
          and ra.workspaceKnown and rb.workspaceKnown and ca.workspace == cb.workspace
          and ra.layout == rb.layout
          and (ra.layout == 'h_tiles' or ra.layout == 'h_accordion') then
          partner[a.id], partner[b.id] = b.id, a.id
          pairSlot[a.id], pairSlot[b.id] = 0, 1
        end
      end
      P.pairPartner = partner
      for _, c in ipairs(cache) do
        c.partner = partner[c.id]
        c.pairSlot = pairSlot[c.id]
        local parts = {}
        if c.text ~= c.app then parts[#parts + 1] = c.app end
        parts[#parts + 1] = 'Space ' .. c.workspace
        if monitorCount > 1 and c.monitor then parts[#parts + 1] = c.monitor end
        local mate = partner[c.id] and byID[partner[c.id]]
        if mate then
          local label = mate.text
          if mate.app and mate.text ~= mate.app then
            label = mate.app .. ' · ' .. mate.text
          end
          parts[#parts + 1] = '⇄ ' .. label
        end
        c.subText = table.concat(parts, ' · ')
      end
      P.cache, P.byID = cache, byID
      P.panel:prewarm(cache)
      if rawget(_G,'leanmac') and leanmac.overview then leanmac.overview.scheduleRefresh() end
      if byID[P.pendingFocusID] then P.currentID = P.pendingFocusID end
      -- Keep a displayed list stable while the user cycles or searches.
      if P.active and P.loading then
        P.loading = false
        displayChoices()
        present()
        if #cache == 0 then
          P.cancel()
        elseif P.acceptAfterLoad then
          P.confirm()
        end
      end
    end
    if P.refreshQueued and not P.stopping then P.refresh() end
  end, {'list-windows', '--all', '--format',
    '%{window-id} %{app-name} %{app-bundle-id} %{window-title} %{workspace} %{monitor-name} %{app-pid} %{workspace-is-focused} %{workspace-is-visible} %{window-parent-container-layout} %{workspace-root-container-layout}', '--json'})
  P.refreshTask = task
  -- Construction or launch failure gets the same bounded cleanup as a nonzero
  -- exit: keep the previous cache, release a loading picker, drain the queue.
  if not task then failed('AeroSpace is unavailable'); return end
  local startOk, started = pcall(task.start, task)
  if not startOk or not started then failed('AeroSpace is unavailable'); return end
  P.refreshTimeout = hs.timer.doAfter(2, function()
    if task ~= P.refreshTask then return end -- stale timer for a reaped task
    P.refreshTimeout = nil
    P.refreshTask = nil
    task:terminate()
    if P.active and P.loading then P.cancel(); hs.alert.show('AeroSpace is not responding') end
    if P.refreshQueued and not P.stopping then P.refresh() end
  end)
end
local function scheduleRefresh()
  if P.refreshDebounce then P.refreshDebounce:stop() end
  P.refreshDebounce = hs.timer.doAfter(0.15, P.refresh)
end
-- One idle event subscription, no recurring window polling.
function P.subscribe()
  P.buffer = ''
  P.subscriber = hs.task.new(cli, function()
    P.subscriber = nil
    if P.stopping then return end
    P.reconnect = hs.timer.doAfter(3, P.subscribe)
  end, function(_, stdout, _)
    P.buffer = P.buffer .. (stdout or '')
    while true do
      local newline = P.buffer:find('\n', 1, true)
      if not newline then break end
      local line = P.buffer:sub(1, newline - 1)
      P.buffer = P.buffer:sub(newline + 1)
      local ok, event = pcall(hs.json.decode, line)
      if ok and type(event) == 'table' then
        if event._event == 'focus-changed' then noteFocus(event.windowId) end
        if event._event == 'focused-workspace-changed' then P.focusedWorkspace = event.workspace end
        scheduleRefresh()
      end
    end
    return true
  end, {'subscribe', 'focus-changed', 'window-detected', 'focused-workspace-changed'})
  P.subscriber:start()
end
function P.start(holdMode, reverse)
  local began = hs.timer.absoluteTime()
  if P.active then
    if P.panel.opening or P.panel:ownsKeyboard() then P.step(reverse and -1 or 1); return end
    P.dismiss()
  end
  cancelFocus()
  if hs.eventtap.isSecureInputEnabled() then
    hs.alert.show('Secure Input is active; leave the password field and retry'); return
  end
  P.active, P.holdMode = true, holdMode
  P.loading = #P.cache == 0
  -- Subscription events are asynchronous. Read just the focused window now,
  -- otherwise a quick workspace switch can rank the previous workspace first.
  local focused = hs.window.focusedWindow()
  local focusedID = focused and focused:id()
  P.originID = focusedID and focusedID > 0 and focusedID or P.currentID
  local origin = P.byID and P.byID[P.originID]
  P.originChoice = origin
  P.originWorkspace = (origin and origin.workspace) or P.focusedWorkspace
  P.steps = reverse and -1 or 1
  P.acceptAfterLoad = false
  P.events:start()
  local screen = (focused and focused:screen()) or hs.screen.mainScreen()
  local frame = screen and screen:frame()
  P.screenFrame = frame and {x=frame.x,y=frame.y,w=frame.w,h=frame.h} or nil
  if P.loading then
    P.choices = {}
  else
    displayChoices()
  end
  present()
  P.lastOpenMs = (hs.timer.absoluteTime() - began) / 1000000
  if holdMode and not hs.eventtap.checkKeyboardModifiers().alt then P.confirm() end
  -- Refresh for the next invocation; never block or reorder this one.
  scheduleRefresh()
end
local previousShutdown = hs.shutdownCallback
hs.shutdownCallback = function()
  P.stopping = true
  P.panel:shutdown()
  cancelFocus()
  if P.subscriber then P.subscriber:terminate() end
  if P.refreshTask then P.refreshTask:terminate() end
  if P.focusTask then P.focusTask:terminate() end
  if previousShutdown then previousShutdown() end
end
P.refresh()
P.subscribe()
P.forward = hs.hotkey.bind({'alt'}, 'tab', function() P.start(true, false) end)
P.backward = hs.hotkey.bind({'alt','shift'}, 'tab', function() P.start(true, true) end)
P.search = U.bind('picker_search', function() P.start(false, false) end)
return P
