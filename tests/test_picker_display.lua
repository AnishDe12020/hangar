-- Presentation, pair-inheritance, ordering, binding and refresh-lifecycle tests.
-- Same LuaSkin runner as test_picker_tabs.lua; no live app calls.
local tests = 0
local function check(v, msg) assert(v, msg or 'check failed'); tests = tests + 1 end

-- window-links with an in-memory settings store that counts writes
local settingsStore, settingsWrites = {}, 0
local linksEnv = {hs = {settings = {
  get = function(k) return settingsStore[k] end,
  set = function(k, v) settingsWrites = settingsWrites + 1; settingsStore[k] = v end}}}
setmetatable(linksEnv, {__index = _G})
local L = assert(loadfile(KIT .. '/config/window-links.lua', 't', linksEnv))()

-- recording mocks
local chooser = {list = {}, queryStr = '', row = 0, rowsN = 0, placeholder = '',
  visible = false, probes = 0, selected = nil, frontmost = true}
function chooser:ownsKeyboard() return self.visible and self.frontmost end
function chooser:rows(n) if n ~= nil then self.rowsN = n; return self end return self.rowsN end
function chooser:width(n) if n ~= nil then self.w = n; return self end return self.w end
function chooser:searchSubText() return self end
function chooser:bgDark(dark) self.dark = dark; return self end
function chooser:fgColor(t) self.fg = t; return self end
function chooser:subTextColor(t) self.sub = t; return self end
function chooser:placeholderText(t) if t ~= nil then self.placeholder = t; return self end return self.placeholder end
function chooser:query(q) if q ~= nil then self.queryStr = q; return self end return self.queryStr end
function chooser:choices(l) if l ~= nil then self.list = l; return self end return self.list end
function chooser:selectedRow(n) if n ~= nil then self.row = n; return self end return self.row end
function chooser:filtered()
  local out = {}
  for _, ch in ipairs(self.list) do
    if self.queryStr == ''
      or (ch.text or ''):lower():find(self.queryStr:lower(), 1, true)
      or (ch.subText or ''):lower():find(self.queryStr:lower(), 1, true) then
      out[#out + 1] = ch
    end
  end
  return out
end
function chooser:selectedRowContents(i)
  self.probes = self.probes + 1
  return self:filtered()[i or self.row] or {}
end
function chooser:show() self.visible = true; return self end
function chooser:hide(done)
  self.visible = false; if self.hideFn then self.hideFn() end
  if self.deferHide then self.hiddenCallback=done elseif done then done() end
  return self
end
function chooser:isVisible() return self.visible end
function chooser:select() self.selected = self:filtered()[self.row]; self.visible=false; if self.done then self.done(self.selected) end; return self end
function chooser:hideCallback(fn) self.hideFn = fn; return self end
-- Presentation boundary double, not an AppKit/API mock. Actual native behavior
-- is exercised by the compiled helper protocol tests and live visual checks.
function chooser:present(choices, frame, hold, step, loading, origin)
  self.list=choices; self.frame=frame; self.hold=hold; self.loading=loading; self.origin=origin
  self.queryStr=''; self.row=1; self.visible=true; self.presentations=(self.presentations or 0)+1
  if hold and #choices>0 then self:step(step) end
end
function chooser:step(delta)
  local count=#self:filtered()
  if count>0 then self.row=((self.row-1+delta)%count)+1 end
end
function chooser:confirm() self:select() end
function chooser:navigate(axis,delta) self.navigation={axis,delta} end
function chooser:prewarm() end
function chooser:shutdown() self.visible=false end
function chooser:canFocus() return self.nativeFocus==true end
function chooser:focus(args,callback)
  local t={args=args,callback=callback,killed=false}
  function t:start()
    self.started=true; chooser.residentTask=self
    if chooser.syncFocusFailure then self.callback(1,'','write failed'); return false end
    return true
  end
  function t:terminate() self.killed=true end
  function t:finish(code,result)
    if not self.killed then self.callback(code or 0,'',code and 'failed' or '',result or {nativeMs=9}) end
  end
  return t
end

local tasks = {}
local failTaskNew, failTaskStart = false, false
local function taskNew(cmd, cb, a, b)
  if failTaskNew then return nil end
  local stream = type(a) == 'function' and a or nil
  local t = {cmd = cmd, cb = cb, stream = stream, args = stream and b or a,
    started = false, killed = false, done = false}
  function t:start()
    if failTaskStart then return nil end
    self.started = true; tasks[#tasks + 1] = self; return true
  end
  function t:terminate() self.killed = true end
  function t:isRunning() return self.started and not self.killed end
  function t:finish(code, out) self.done = true; self.cb(code, out or '', '') end
  return t
end

local timers = {}
local function timerNew(sec, fn)
  local t = {sec = sec, fn = fn, stopped = false}
  function t:stop() self.stopped = true end
  timers[#timers + 1] = t
  return t
end
local function fireTimer(sec)
  for i = #timers, 1, -1 do
    local t = timers[i]
    if not t.stopped and t.sec == sec then t.stopped = true; t.fn(); return t end
  end
end

local tap = {running = false}
function tap:start() self.running = true; return self end
function tap:stop() self.running = false; return self end
local tapFn, decodeResult, focusedWin, altHeld, screenW = nil, {}, nil, true, 1512
local alerts, overviewSends = {}, 0
local env = {hs = {
  fs = {attributes = function(_, mode) if mode ~= nil then return nil end return true end},
  configdir = '/fixture',
  chooser = {new = function(cb) chooser.done = cb; return chooser end},
  eventtap = {new = function(_, fn) tapFn = fn; return tap end,
    event = {types = {keyDown = 1, flagsChanged = 2}},
    isSecureInputEnabled = function() return false end,
    checkKeyboardModifiers = function() return {alt = altHeld} end},
  hotkey = {bind = function() return {enabled = true} end},
  task = {new = taskNew},
  timer = {doAfter = timerNew, absoluteTime = function() return 0 end},
  window = {focusedWindow = function() return focusedWin end,
    get = function() return nil end, orderedWindows = function() return {} end},
  keycodes = {map = {escape = 53, tab = 48, ['return'] = 36}},
  screen = {mainScreen = function()
    return {frame = function() return {w = screenW, h = 900} end}
  end},
  alert = {show = function(m) alerts[#alerts + 1] = m end},
  json = {decode = function() return decodeResult end},
  image = {imageFromAppBundle = function()
    return setmetatable({}, {__index = function() return function(self) return self end end})
  end},
  axuielement = {applicationElementForPID = function() return nil end},
  printf = function() end,
}}
local realRequire = require
env.require = function(name)
  if name == 'window-links' then return L end
  if name == 'picker-panel' then return {new=function(done) chooser.done=done; return chooser end} end
  return realRequire(name)
end
setmetatable(env, {__index = _G})
rawset(_G, 'leanmac', {overview = {scheduleRefresh = function() overviewSends = overviewSends + 1 end}})
local P = assert(loadfile(KIT .. '/config/window-picker.lua', 't', env))()

local function w(id, pid, app, title, ws, monitor, layout, root, visible, focused)
  return {['window-id'] = id, ['app-pid'] = pid, ['app-name'] = app,
    ['app-bundle-id'] = 'fixture.' .. app, ['window-title'] = title,
    workspace = ws, ['monitor-name'] = monitor,
    ['workspace-is-visible'] = visible == true, ['workspace-is-focused'] = focused == true,
    ['window-parent-container-layout'] = layout or 'v_accordion',
    ['workspace-root-container-layout'] = root or 'v_accordion'}
end
local function refreshTask()
  for i = #tasks, 1, -1 do
    local t = tasks[i]
    if t.args and t.args[1] == 'list-windows' and not t.killed and not t.done then return t end
  end
end
local function refreshCount()
  local n = 0
  for _, t in ipairs(tasks) do
    if t.args and t.args[1] == 'list-windows' then n = n + 1 end
  end
  return n
end
local function finishRefresh(rows, code)
  decodeResult = rows
  if not refreshTask() then P.refresh() end
  local t = refreshTask()
  assert(t, 'no refresh task in flight')
  t:finish(code or 0, 'json')
  return t
end
local function orderIDs(list)
  local ids = {}
  for _, c in ipairs(list) do ids[#ids + 1] = c.id end
  return table.concat(ids, ',')
end
local function key(code, flags)
  return {getType = function() return 1 end, getKeyCode = function() return code end,
    getFlags = function() return flags or {} end}
end
local function flagsEvent(f) return {getType = function() return 2 end, getFlags = function() return f end} end

-- ---- presentation: title primary, app/space/monitor secondary ----
finishRefresh({
  w(1, 101, 'Ghostty', '~/src — zsh', '1', 'Main', 'h_tiles', 'h_tiles', true, true),
  w(2, 102, 'Aside', 'Spec · draft', '1', 'Main', 'h_tiles', 'h_tiles', true, false),
  w(3, 103, 'Finder', '', '2', 'Main', 'v_accordion', 'v_accordion', false, false),
})
check(#P.cache == 3, 'cache built')
check(P.panel == chooser, 'native presentation adapter replaces the chooser')
check(P.chooser == nil, 'no text chooser is constructed')
local c1, c2, c3 = P.byID[1], P.byID[2], P.byID[3]
check(c1.text == '~/src — zsh', 'title is the primary row text')
check(c1.subText:find('Ghostty', 1, true), 'app name stays searchable in subtext')
check(c1.subText:find('Space 1', 1, true), 'numbered space stays searchable in subtext')
check(not c1.subText:find('[1]', 1, true), 'Space N avoids the Command+number row-shortcut look')
check(not c1.subText:find('Main', 1, true), 'single-monitor setup omits monitor name')
check(c3.text == 'Finder', 'empty title falls back to app name')
check(c3.subText == 'Space 2', 'app-fallback row keeps its space context')
check(c1.app == 'Ghostty' and c1.title == '~/src — zsh', 'raw identity fields kept beside display text')
check(c1.image ~= nil, 'app icon retained')

-- inherited pair metadata: whole-space two-window split adopted and labelled
check(P.pairPartner[1] == 2 and P.pairPartner[2] == 1, 'whole-space pair adopted')
check(c1.partner == 2 and c2.partner == 1, 'native GUI receives exact symmetric partner IDs')
check(c1.subText:find('⇄ Aside · Spec · draft', 1, true), 'cross-app partner names app and title')
check(c2.subText:find('⇄ Ghostty · ~/src — zsh', 1, true), 'partner annotation is symmetric')
check(not c3.subText:find('⇄', 1, true), 'standalone row has no partner marker')
check(overviewSends == 1, 'overview consumers still notified per refresh')

-- multi-monitor context is legible when a second monitor exists
finishRefresh({
  w(1, 101, 'Ghostty', 'term', '1', 'Main', 'v_accordion', 'v_accordion', true, true),
  w(4, 104, 'Dia', 'diagram', '2', 'External', 'v_accordion', 'v_accordion', true, false),
})
check(P.byID[4].subText:find('External', 1, true), 'second monitor named in subtext')
check(P.byID[1].subText:find('Main', 1, true), 'primary monitor named when >1 monitor')
check(#L.pairs == 0, 'previous adopted pair pruned when partner vanished')

-- unchanged pair metadata must not rewrite settings on every refresh
local identical = {
  w(4, 104, 'A', 'first', '1', 'Main', 'h_tiles', 'v_accordion', true, true),
  w(5, 105, 'B', 'second', '1', 'Main', 'h_tiles', 'v_accordion', true, false),
  w(6, 106, 'C', 'third', '1', 'Main', 'v_accordion', 'v_accordion', true, false),
}
L.link({id = 4, pid = 104}, {id = 5, pid = 105})
finishRefresh(identical)
check(#L.pairs == 1, 'explicit pair survives reconcile with a third window')
local w0 = settingsWrites
finishRefresh(identical)
check(settingsWrites == w0, 'identical refresh does not rewrite pair settings')
L.reconcile({{id = 4, pid = 104, workspace = '1', layout = 'h_tiles', root = 'v_accordion'},
  {id = 5, pid = 105, workspace = '1', layout = 'h_tiles', root = 'v_accordion'},
  {id = 6, pid = 106, workspace = '1', layout = 'v_accordion', root = 'v_accordion'}})
check(settingsWrites == w0, 'direct reconcile of identical data does not write')

-- pair lifecycle: cross-space, float, reused id, stale window all prune safely
local rows = {
  w(4, 104, 'A', 'first', '1', 'Main', 'h_tiles', 'v_accordion', true, true),
  w(5, 105, 'B', 'second', '2', 'Main', 'h_tiles', 'v_accordion', true, false),
  w(6, 106, 'C', 'third', '1', 'Main', 'v_accordion', 'v_accordion', true, false),
}
finishRefresh(rows)
check(#L.pairs == 0 and not P.pairPartner[4], 'cross-workspace pair dropped')
L.link({id = 4, pid = 104}, {id = 5, pid = 105})
rows[2] = w(5, 105, 'B', 'second', '1', 'Main', 'floating', 'v_accordion', true, false)
finishRefresh(rows)
check(#L.pairs == 0 and not P.pairPartner[4], 'floated member drops the pair')
L.link({id = 4, pid = 104}, {id = 5, pid = 105})
rows[2] = w(5, 999, 'B', 'second', '1', 'Main', 'h_tiles', 'v_accordion', true, false)
finishRefresh(rows)
check(#L.pairs == 0, 'reused window id with a different pid drops the pair')
L.link({id = 4, pid = 104}, {id = 5, pid = 105})
finishRefresh({rows[1], rows[3]})
check(#L.pairs == 0, 'closed partner prunes the pair')

-- field-poor snapshots must not rewrite stored pair metadata
L.link({id = 4, pid = 104}, {id = 5, pid = 105})
local poor = {
  w(4, 104, 'A', 'first', '1', 'Main', 'h_tiles', 'v_accordion', true, true),
  w(5, 105, 'B', 'second', '1', 'Main', 'h_tiles', 'v_accordion', true, false),
}
poor[1]['window-parent-container-layout'] = nil
finishRefresh(poor)
check(#L.pairs == 1, 'incomplete layout data preserves stored pairs')
check(not P.pairPartner[4], 'member with unconfirmed layout is not annotated')

-- Stored pairs annotate only members confirmed by their own live rows: an
-- unrelated field-poor row must not hide that a member has floated.
local confirmed = {
  w(4, 104, 'A', 'first', '1', 'Main', 'h_tiles', 'v_accordion', true, true),
  w(5, 105, 'B', 'second', '1', 'Main', 'h_tiles', 'v_accordion', true, false),
  w(6, 106, 'C', 'third', '1', 'Main', 'v_accordion', 'v_accordion', true, false),
}
confirmed[3]['app-pid'] = nil
finishRefresh(confirmed)
check(#L.pairs == 1, 'unrelated field-poor row still preserves the store')
check(P.pairPartner[4] == 5, 'confirmed members annotate despite the partial snapshot')
local floaty = {
  w(4, 104, 'A', 'first', '1', 'Main', 'floating', 'v_accordion', true, true),
  w(5, 105, 'B', 'second', '1', 'Main', 'h_tiles', 'v_accordion', true, false),
  w(6, 106, 'C', 'third', '1', 'Main', 'v_accordion', 'v_accordion', true, false),
}
floaty[3]['app-pid'] = nil
finishRefresh(floaty)
check(#L.pairs == 1, 'store preserved while another row is incomplete')
check(not P.pairPartner[4] and not P.pairPartner[5],
  'floating member is not annotated from stored data')
local noWs = {
  w(4, 104, 'A', 'first', '1', 'Main', 'h_tiles', 'v_accordion', true, true),
  w(5, 105, 'B', 'second', '1', 'Main', 'h_tiles', 'v_accordion', true, false),
  w(6, 106, 'C', 'third', '1', 'Main', 'v_accordion', 'v_accordion', true, false),
}
noWs[2].workspace = nil
noWs[3]['app-pid'] = nil
finishRefresh(noWs)
check(#L.pairs == 1, 'missing member workspace still preserves the store')
check(not P.pairPartner[4] and not P.pairPartner[5],
  'member without a real workspace is not annotated')
noWs[3]['app-pid'] = 106
finishRefresh(noWs)
check(#L.pairs == 1, 'missing workspace alone makes the snapshot incomplete')
noWs[1].workspace = nil
finishRefresh(noWs)
check(#L.pairs == 1 and not P.pairPartner[4], 'two unknown workspaces do not form an inferred pair')
noWs[1].workspace, noWs[2].workspace = '', ''
finishRefresh(noWs)
check(#L.pairs == 1 and not P.pairPartner[4], 'blank workspace fields preserve the store without annotation')
local wn = settingsWrites
finishRefresh({})
check(#L.pairs == 1 and settingsWrites == wn, 'empty window list must not rewrite persisted pairs')
check(not P.pairPartner[4], 'no live rows means no annotation')

-- a partner is identified by app and title whenever they differ
L.link({id = 7, pid = 107}, {id = 8, pid = 108})
finishRefresh({
  w(7, 107, 'Ghostty', 'one', '1', 'Main', 'h_tiles', 'v_accordion', true, true),
  w(8, 108, 'Ghostty', 'two', '1', 'Main', 'h_tiles', 'v_accordion', true, false),
  w(9, 109, 'C', 'third', '1', 'Main', 'v_accordion', 'v_accordion', true, false),
})
check(P.byID[7].subText:find('⇄ Ghostty · two', 1, true), 'same-app partner names app and title')
check(P.byID[8].subText:find('⇄ Ghostty · one', 1, true), 'symmetric same-app annotation')
L.unlink(7); L.link({id = 7, pid = 107}, {id = 9, pid = 109})
finishRefresh({
  w(7, 107, 'Ghostty', 'one', '1', 'Main', 'h_tiles', 'v_accordion', true, true),
  w(9, 109, 'C', '', '1', 'Main', 'h_tiles', 'v_accordion', true, false),
})
check(P.byID[7].subText:find('⇄ C', 1, true), 'empty-title partner names the app once')
check(not P.byID[7].subText:find('⇄ C · C', 1, true), 'app fallback is not duplicated')

-- ordering: origin, same workspace by recency, other visible, hidden
finishRefresh({
  w(10, 110, 'A', 'ten', '2', 'Main', 'v_accordion', 'v_accordion', true, false),
  w(11, 111, 'B', 'eleven', '1', 'Main', 'v_accordion', 'v_accordion', true, false),
  w(12, 112, 'C', 'twelve', '1', 'Main', 'v_accordion', 'v_accordion', true, false),
  w(13, 113, 'D', 'thirteen', '3', 'Main', 'v_accordion', 'v_accordion', false, false),
  w(14, 114, 'E', 'fourteen', '1', 'Main', 'v_accordion', 'v_accordion', true, false),
})
P.recency = {}; P.recency[12] = 5; P.recency[11] = 3; P.recency[14] = 2
focusedWin = {id = function() return 11 end, pid = function() return 111 end, screen=function() return nil end}
P.start(false, false)
check(orderIDs(P.choices) == '11,12,14,10,13', 'origin, workspace, visible, hidden order')
check(#chooser.list == 5, 'all windows reach the native panel')
check(chooser.frame.w == 1512, 'native panel receives the actual display frame')
check(chooser.hold == false, 'search mode reaches the native panel')
check(P.active and chooser.visible, 'chooser shown')

-- a background refresh while open must not reorder the displayed list
finishRefresh({
  w(15, 115, 'F', 'fifteen', '1', 'Main', 'v_accordion', 'v_accordion', true, false),
  w(10, 110, 'A', 'ten', '2', 'Main', 'v_accordion', 'v_accordion', true, false),
  w(11, 111, 'B', 'eleven', '1', 'Main', 'v_accordion', 'v_accordion', true, false),
})
check(#P.cache == 3 and P.byID[15] ~= nil, 'cache updated underneath')
check(orderIDs(P.choices) == '11,12,14,10,13', 'displayed order stable until dismissed')
P.cancel()
check(not P.active and not chooser.visible, 'cancel hides the chooser')

-- ---- binding semantics: cycle, wrap, reverse, escape, confirm, release-option ----
P.recency = {}
finishRefresh({
  w(20, 120, 'A', 'aa', '1', 'Main', 'v_accordion', 'v_accordion', true, true),
  w(21, 121, 'B', 'bb', '1', 'Main', 'v_accordion', 'v_accordion', true, false),
  w(22, 122, 'C', 'cc', '2', 'Main', 'v_accordion', 'v_accordion', true, false),
})
focusedWin = {id = function() return 20 end, pid = function() return 120 end, screen=function() return nil end}
screenW = 1024
P.start(true, false)
check(chooser.frame.w == 1024, 'narrow screen dimensions reach AppKit')
check(chooser.row == 2, 'hold-mode opens on the second row')
check(chooser.hold, 'hold-mode passed to native panel')
check(tapFn(key(48)) == false and chooser.row == 2, 'plain Tab belongs to AppKit, never the global hook')
P.start(true,false)
check(chooser.row == 3, 'repeated Option+Tab binding steps forward')
check(tapFn(key(48, {shift = true})) == false, 'plain Shift+Tab belongs to AppKit')
P.start(true,true)
check(chooser.row == 2, 'Option+Shift+Tab binding steps back')
check(tapFn(key(124, {alt=true})) == true and chooser.navigation[1]=='horizontal',
  'Option+Right stays in the panel instead of triggering snapping')
check(tapFn(key(125, {alt=true})) == true and chooser.navigation[1]=='vertical',
  'Option+Down navigates rows instead of triggering snapping')
check(tapFn(key(123)) == false, 'plain arrows pass to native search/navigation')
P.step(1); P.step(1)
check(chooser.row == 1, 'cycling wraps around the list')
check(tapFn(key(999)) == false, 'unhandled keys pass through')
check(tapFn(key(53)) == false and P.active, 'Escape reaches the native window monitor')
chooser.done(nil,'escape'); chooser.visible=false
check(not P.active and not tap.running, 'native Escape completion stops the tap')
check(tapFn(key(48)) == false, 'inactive tap swallows nothing')

P.start(true, false)
check(chooser.row == 2, 'reopened on second row')
chooser.probes = 0
P.step(1)
check(chooser.probes == 0, 'empty query: no per-row chooser probes per Tab')
chooser:query('b')
chooser.probes = 0
P.step(1)
check(chooser.probes == 0, 'search cycling stays entirely inside the native renderer')
check(chooser.row <= 1, 'selection stays inside the filtered set')
chooser:query('')
check(tapFn(flagsEvent({})) == false, 'flags event is not consumed')
check(chooser.selected ~= nil and chooser.selected.id == 20, 'releasing Option commits the selected row')
check(fireTimer(0.12) == nil, 'native confirmed-close selection has no artificial focus delay')
local focusTask = tasks[#tasks]
check(focusTask.args[1] == 'focus' and focusTask.args[3] == '20', 'fallback focus keeps exact window id')
check(not P.active, 'commit dismisses the picker')

-- search mode: Enter confirms
P.start(false, false)
check(not chooser.hold, 'search mode does not release-to-commit')
check(tapFn(key(36)) == false and P.active, 'global hook never consumes Return')
check(tapFn(key(76)) == false and P.active, 'global hook never consumes keypad Enter')
chooser:confirm()
check(chooser.selected ~= nil and chooser.selected.id == 20, 'Enter confirms the selected row')
fireTimer(0.12)

-- Lost native terminal message: Lua is visible but another app has focus.
for _,code in ipairs({36,76,48,53,124}) do
  P.start(false,false); chooser.frontmost=false
  check(tapFn(key(code,{alt=code==124}))==false, 'stale picker passes the original key through')
  check(not P.active and not chooser.visible and not tap.running, 'stale ownership clears without restoring origin')
  chooser.frontmost=true
end
P.start(false,false); chooser.frontmost=false
local presentations=chooser.presentations
P.start(true,false)
check(P.active and chooser.presentations==presentations+1, 'Option+Tab reopens a dead session')
chooser.frontmost=true; P.dismiss()
P.start(true,false); chooser.frontmost=false; chooser.opening=true
check(tapFn(key(36))==false and P.active, 'opening grace does not intercept Return')
check(tapFn(key(124,{alt=true}))==false, 'opening grace does not claim Option-arrows before focus')
chooser.opening=false; chooser.frontmost=true; P.dismiss()

-- adaptive cap: more than ten windows clamps to ten rows
local many = {}
for i = 1, 14 do many[i] = w(100 + i, 200 + i, 'App' .. i, 't' .. i, '1', 'Main', 'v_accordion', 'v_accordion', i == 1, i == 1) end
finishRefresh(many)
screenW = 3840
P.start(false, false)
check(chooser.frame.w == 3840, 'wide display dimensions reach AppKit')
check(#chooser.list == 14, 'large lists are delivered intact for native scrolling')
P.cancel()

-- ---- refresh lifecycle: coalescing, failure, timeout, late callbacks ----
local n0 = refreshCount()
P.refresh()
P.refresh(); P.refresh()
check(refreshCount() == n0 + 1, 'calls during an in-flight refresh spawn no task')
check(P.refreshQueued == true, 'in-flight call is remembered, not dropped')
finishRefresh({w(30, 130, 'X', 'x', '1', 'Main', 'v_accordion', 'v_accordion', true, true)})
check(refreshCount() == n0 + 2, 'exactly one follow-up refresh spawned')
check(P.refreshQueued == false, 'queued flag consumed')
check(P.byID[30] ~= nil, 'cache refreshed')
finishRefresh({w(31, 131, 'Y', 'y', '1', 'Main', 'v_accordion', 'v_accordion', true, true)})
check(refreshCount() == n0 + 2, 'no follow-up without new events')
check(P.byID[31] ~= nil and P.byID[30] == nil, 'latest snapshot wins')

-- failure while loading cancels with an alert instead of hanging
local previousLeanmac=env.leanmac
env.leanmac={groups={busy=false,layoutEpoch=1}}
P.refresh()
env.leanmac.groups.busy=true
finishRefresh({w(32,132,'Transient','temporary','1','Main','floating','v_accordion',true,true)})
check(P.byID[32]==nil and P.byID[31]~=nil, 'in-flight mutation snapshot cannot replace pair cache')
local duringMutation=refreshCount()
P.refresh()
check(refreshCount()==duringMutation, 'no discovery task during pair mutation')
env.leanmac.groups.busy=false;env.leanmac.groups.layoutEpoch=2
P.refresh()
env.leanmac.groups.layoutEpoch=3
finishRefresh({w(32,132,'Transient','temporary','1','Main','floating','v_accordion',true,true)})
check(P.byID[32]==nil and P.refreshTask~=nil, 'old generation is discarded and refreshed')
finishRefresh({w(31,131,'Y','y','1','Main','v_accordion','v_accordion',true,true)})
env.leanmac=previousLeanmac

-- failure while loading cancels with an alert instead of hanging
P.cache = {}
P.start(false, false)
check(P.loading and chooser.visible, 'empty cache shows loading state')
fireTimer(0.15)
finishRefresh({}, 1)
check(not P.active and not chooser.visible, 'failed load cancels the picker')
check(alerts[#alerts] == 'AeroSpace is unavailable', 'failure alert shown')

-- timeout: queued event re-runs after terminate; the late callback is ignored
local preTimeoutCount = refreshCount()
P.refresh(); P.refresh()
local timedOut = refreshTask()
fireTimer(2)
check(timedOut.killed, 'stuck refresh task terminated at the bound')
check(P.refreshTask ~= timedOut and P.refreshTask ~= nil, 'queued rerun spawned after timeout')
decodeResult = {w(40, 140, 'Stale', 'stale', '1', 'Main', 'v_accordion', 'v_accordion', true, true)}
timedOut:finish(0, 'json')
check(P.byID[40] == nil, 'late completion of a timed-out task is ignored')
check(refreshCount() == preTimeoutCount + 2, 'late callback spawns nothing')
finishRefresh({w(41, 141, 'Fresh', 'fresh', '1', 'Main', 'v_accordion', 'v_accordion', true, true)})
check(P.byID[41] ~= nil and P.byID[40] == nil, 'follow-up snapshot applied')

-- debounce: burst of subscription events produces one refresh
local subscriber
for _, t in ipairs(tasks) do if t.args and t.args[1] == 'subscribe' then subscriber = t end end
check(subscriber ~= nil and subscriber.stream ~= nil, 'event subscription running')
local debounceCount = refreshCount()
decodeResult = {_event = 'focus-changed', windowId = 41}
subscriber.stream(subscriber, '{"_event":"focus-changed","windowId":41}\n', '')
subscriber.stream(subscriber, '{"_event":"focus-changed","windowId":41}\n', '')
local pending = 0
for _, t in ipairs(timers) do if not t.stopped and t.sec == 0.15 then pending = pending + 1 end end
check(pending == 1, 'burst collapses to one pending refresh')
fireTimer(0.15)
check(refreshCount() == debounceCount + 1, 'debounced refresh ran once')
check(P.recency[41] ~= nil, 'focus-changed event still records recency')
finishRefresh({w(41, 141, 'Fresh', 'fresh', '1', 'Main', 'v_accordion', 'v_accordion', true, true)})

-- constructor failure releases a loading picker like a nonzero exit does
P.cache = {}
P.start(false, false)
check(P.loading and chooser.visible, 'loading picker before constructor failure')
local nCtor = refreshCount()
failTaskNew = true
fireTimer(0.15)
failTaskNew = false
check(refreshCount() == nCtor, 'constructor failure spawns no task')
check(P.refreshTask == nil, 'in-flight state cleared after constructor failure')
check(not P.active and not chooser.visible, 'loading picker released on constructor failure')
check(alerts[#alerts] == 'AeroSpace is unavailable', 'constructor failure uses the standard alert')

-- a task that fails to start gets the same bounded cleanup, not a timeout wait
P.start(false, false)
check(P.loading and chooser.visible, 'loading picker before start failure')
local nStart = refreshCount()
failTaskStart = true
P.refresh()
failTaskStart = false
check(refreshCount() == nStart, 'failed start registers no running task')
check(P.refreshTask == nil, 'in-flight state cleared after start failure')
check(not P.active, 'loading picker released on start failure')
check(alerts[#alerts] == 'AeroSpace is unavailable', 'start failure uses the standard alert')
fireTimer(0.15)
finishRefresh({w(60, 160, 'Z', 'zz', '1', 'Main', 'v_accordion', 'v_accordion', true, true)})
check(P.byID[60] ~= nil, 'refresh recovers after a launch failure')

-- a timeout callback is bound to its own task, not whatever is current
P.refresh()
local taskA = refreshTask()
local timerA = timers[#timers]
check(timerA ~= nil and timerA.sec == 2, 'timeout armed for the in-flight task')
decodeResult = {w(61, 161, 'T', 'tt', '1', 'Main', 'v_accordion', 'v_accordion', true, true)}
taskA:finish(0, 'json')
check(timerA.stopped, 'normal completion disarms its own timeout')
P.refresh()
local taskB = refreshTask()
check(taskB ~= nil and taskB ~= taskA, 'a newer refresh is in flight')
timerA.stopped = false
timerA.fn()
check(not taskB.killed and P.refreshTask == taskB, 'stale timeout leaves the live task alone')
finishRefresh({w(62, 162, 'U', 'uu', '1', 'Main', 'v_accordion', 'v_accordion', true, true)})

-- Group activation validates a fresh snapshot, reveals the partner, and leaves
-- the remembered member key without app-wide activation or layout mutations.
local groupRows={w(70,170,'Aside','browser','1','Main','h_tiles','v_accordion',true,true),
  w(71,171,'Ghostty','terminal','1','Main','h_tiles','v_accordion',true,false)}
L.link({id=70,pid=170},{id=71,pid=171})
finishRefresh(groupRows)
local members={P.byID[70],P.byID[71]}
check(P.validateGroup(members,groupRows), 'fresh valid pair accepted')
check(not P.validateGroup(members,{groupRows[1]}), 'missing member rejected')
check(not P.validateGroup(members,{{}}), 'malformed snapshot rejected')
local raised, stacking={},{}
local livePIDs={[70]=170,[71]=171,[88]=188}
local deadAX={}
local appLookups=0
env.hs.fs.attributes=function(_,mode) return mode and 'file' or true end
local function fixtureWindow(id)
  if not livePIDs[id] then return nil end
  return {id=function() return livePIDs[id] and id end,pid=function() return livePIDs[id] end,
    screen=function() return 'other-screen' end,raise=function()
    raised[#raised+1]=id
    for i=#stacking,1,-1 do if stacking[i]==id then table.remove(stacking,i) end end
    table.insert(stacking,1,id)
  end}
end
env.hs.application={applicationForPID=function(pid)
  return {getWindow=function(_,id)
    appLookups=appLookups+1
    return livePIDs[id]==pid and fixtureWindow(id) or nil
  end}
end}
env.hs.axuielement.windowElement=function(window)
  return {isValid=function() return not deadAX[window:id()] end}
end
env.hs.window.get=function() error('Global AX lookup is forbidden on commit') end
env.hs.window.orderedWindows=function() error('Global AX ordering is forbidden on commit') end
env.hs.screen.allScreens=function() return {'main','other'} end
P.byID[88]={id=88,pid=188,visible=true,monitor='Other'}
env.hs.window.list=function() return {{kCGWindowNumber=88,kCGWindowOwnerPID=188,kCGWindowIsOnscreen=true}} end
env.hs.spaces={activeSpaceOnScreen=function(screen) assert(screen=='other-screen'); return 999 end}
chooser.done(members[2],nil,members)
fireTimer(0.12)
local validation=P.focusTask
check(validation.args[1]=='list-windows', 'group is freshly checked only on commit')
decodeResult=groupRows; validation:finish(0,'json')
local selectedTask=P.focusTask
check(#raised==0, 'group raises wait until the focus transition completes')
check(selectedTask.args[1]=='171' and selectedTask.args[2]=='71', 'last-used member receives exact focus')
check(selectedTask.args[3]=='999' and selectedTask.args[4]=='188', 'other-display front restoration is preserved')
-- WindowServer can raise the previous full-width window over the other member
-- during exact focus. Pre-focus raises cannot fix the resulting occlusion.
stacking={71,99,70}
selectedTask:finish(0,'')
check(appLookups==3, 'each selected window and other-monitor front resolved once; no post-focus rescan')
check(raised[1]==70 and raised[2]==71 and #raised==2, 'both members raised after focus with remembered member last')
check(stacking[1]==71 and stacking[2]==70 and stacking[3]==99, 'both pair members finish above the full-width standalone')
check(P.lastFocus.members[1]==70 and P.lastFocus.members[2]==71, 'activation records the whole group')
local function commitGroup(target)
  raised={}
  chooser.done(target,nil,members); fireTimer(0.12)
  local t=P.focusTask
  decodeResult=groupRows; t:finish(0,'json')
  return P.focusTask
end
selectedTask=commitGroup(members[1])
check(selectedTask.args[1]=='170' and selectedTask.args[2]=='70', 'left member MRU also receives exact focus')
stacking={70,99,71}; selectedTask:finish(0,'')
check(raised[1]==71 and raised[2]==70 and stacking[2]==71, 'reverse MRU direction reveals the whole pair')
selectedTask=commitGroup(members[2])
livePIDs[70]=nil; selectedTask:finish(0,'')
check(#raised==0 and alerts[#alerts]=='Group changed; reopen picker', 'closed partner after focus prevents partial group raises')
livePIDs[70]=170
selectedTask=commitGroup(members[2])
livePIDs[71]=999; selectedTask:finish(0,'')
check(#raised==0, 'reused target ID after focus cannot raise a different process')
livePIDs[71]=171
selectedTask=commitGroup(members[2]); selectedTask:finish(1,'')
check(#raised==0 and alerts[#alerts]=='Window unavailable', 'failed exact focus does not raise a partial group')
selectedTask=commitGroup(members[2]); deadAX[70]=true; selectedTask:finish(0,'')
check(#raised==0, 'closed retained AX object blocks both raises even when ID and PID remain cached')
check(commitGroup(members[2])==nil, 'invalid AX object blocks focus before helper starts')
deadAX[70]=nil
selectedTask=commitGroup(members[2]); P.cancel(); selectedTask:finish(0,'')
check(#raised==0, 'cancelled focus callback cannot bring the old pair forward')
livePIDs[70]=nil
check(commitGroup(members[2])==nil and #raised==0, 'missing member before helper prevents focus entirely')
livePIDs[70]=170
env.hs.window.list=function() return {} end
raised={}
chooser.done(members[2],nil,members); fireTimer(0.12)
validation=P.focusTask
decodeResult={groupRows[1],w(71,171,'Ghostty','terminal','2','Other','h_tiles','v_accordion',true,false)}
validation:finish(0,'json')
check(#raised==0 and P.focusTask==nil, 'moved partner cancels before raising either window')

P.byID[89]={id=89,pid=189,visible=true,monitor='Other'}; livePIDs[89]=189
env.hs.window.list=function() return {
  {kCGWindowNumber=88,kCGWindowOwnerPID=999,kCGWindowIsOnscreen=true},
  {kCGWindowNumber=89,kCGWindowOwnerPID=189,kCGWindowIsOnscreen=true}} end
chooser.done(members[1],nil,{members[1]})
check(P.focusTask.args[4]=='189', 'stale CG owner cannot suppress the valid front behind it')
P.focusTask:finish(0,'')
env.hs.window.list=function() return nil end
chooser.done(members[1],nil,{members[1]})
check(P.focusTask==nil and not P.lastFocus.success, 'unavailable ordering fails closed rather than guessing other-display focus')

-- The single-display fast path skips WindowServer ordering entirely.
env.hs.screen.allScreens=function() return {'main'} end
env.hs.window.list=function() error('Single display must not query the window stack') end
raised={}; chooser.done(members[1],nil,{members[1]})
check(P.focusTask and #P.focusTask.args==2, 'single window on one display focuses directly without restore scan')
P.focusTask:finish(0,'')
check(#raised==1 and raised[1]==70 and P.lastFocus.success, 'singleton raises only its retained exact target')
chooser.nativeFocus=true
raised={}; chooser.done(members[1],nil,{members[1]})
check(P.focusTask==chooser.residentTask and P.lastFocus.transport=='resident','ready picker routes exact focus through resident process')
check(P.focusTask.args.id==70 and P.focusTask.args.pid==170 and #P.focusTask.args.restores==0,'resident payload retains exact identity')
P.focusTask:finish(0,{nativeMs=7})
check(#raised==1 and raised[1]==70 and P.lastFocus.nativeMs==7,'resident completion keeps post-focus exact AX raise')
raised={}; chooser.done(members[1],nil,{members[1]}); local cancelledResident=P.focusTask
P.cancel(); cancelledResident:finish(0,{nativeMs=7})
check(#raised==0,'cancelled resident callback cannot raise an old target')
local alertCount=#alerts
chooser.syncFocusFailure=true; chooser.done(members[1],nil,{members[1]}); chooser.syncFocusFailure=false
check(P.focusTask==nil and #alerts==alertCount+1,'synchronous resident start failure completes once without duplicate rejection')
chooser.nativeFocus=false
local singleCount=appLookups
env.hs.application.applicationForPID=function() return nil end
chooser.done(members[1],nil,{members[1]})
check(P.focusTask==nil and appLookups==singleCount and not P.lastFocus.success, 'missing owner aborts before focus')
env.hs.application.applicationForPID=function(pid)
  return {getWindow=function(_,id) appLookups=appLookups+1; return fixtureWindow(id) end}
end
livePIDs[70]=999
chooser.done(members[1],nil,{members[1]})
check(P.focusTask==nil and not P.lastFocus.success, 'recycled target PID is rejected even if app lookup returns it')
livePIDs[70]=170

-- Programmatic cancel waits for a hide acknowledgement; reopening cancels it.
chooser.deferHide=true
P.active=true; P.originChoice=members[1]
P.cancel(); check(P.focusTask==nil and chooser.hiddenCallback~=nil, 'cancel does not focus before hide ack')
chooser.hiddenCallback(); check(P.focusTask~=nil, 'confirmed hide permits immediate origin restore')
P.focusTask:finish(0,'')
P.active=true; P.cancel(); local lateHide=chooser.hiddenCallback
P.dismiss(); lateHide(); check(P.focusTask==nil, 'superseded hide acknowledgement cannot restore old focus')
chooser.deferHide=false

-- shutdown: a pending debounce or direct call must not spawn new work
P.start(false, false)
P.cancel()
local nStop = refreshCount()
env.hs.shutdownCallback()
check(P.stopping == true, 'shutdown flag set')
fireTimer(0.15)
P.refresh()
check(refreshCount() == nStop, 'no refresh starts after shutdown')

print(tests .. ' picker display/pair/refresh tests passed')
