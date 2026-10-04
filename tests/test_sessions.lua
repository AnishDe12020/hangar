local function copy(v)
  if type(v) ~= 'table' then return v end
  local r = {}; for k, x in pairs(v) do r[k] = copy(x) end; return r
end
local source = io.open(KIT .. '/config/hangar-sessions.lua')
assert(source, 'Sessions module is missing'); source:close()
local module = assert(loadfile(KIT .. '/config/hangar-sessions.lua'))()
local now, disk, failWrite, notifications, timer, wake = 1000, nil, false, {}, nil, nil
local deps = {
  now = function() return now end,
  read = function() return copy(disk) end,
  write = function(state) if failWrite then return nil, 'disk unavailable' end; disk = copy(state); return true end,
  after = function(seconds, fn)
    timer = {seconds = seconds, callback = fn, stop = function(self) self.stopped = true end}; return timer
  end,
  watch = function(fn) wake = fn; return {stop = function() end} end,
  notify = function(title, text, click)
    -- Completion must already be on disk before delivering anything.
    notifications[#notifications + 1] = {title = title, text = text, click = click, state = copy(disk)}
    return true
  end,
}
local S = module.new(deps)
assert(S.startFocus({focusMinutes = 1, breakMinutes = 1, longBreakMinutes = 2}).ok)
assert(S.status().focus.endsAt == 1060 and timer.seconds == 60)
now = 1020
assert(S.pauseFocus().ok and S.status().focus.remainingSeconds == 40)
now = 1100; S.shutdown(); S = module.new(deps)
assert(S.status().focus.state == 'paused' and S.status().focus.remainingSeconds == 40)
assert(S.resumeFocus().ok and S.status().focus.endsAt == 1140)
now = 1200; wake()
assert(S.status().focus.state == 'awaiting_next' and S.status().focus.nextPhase == 'break')
assert(#notifications == 1 and notifications[1].state.focus.state == 'awaiting_next')
S.shutdown(); S = module.new(deps)
assert(#notifications == 1, 'reload must not redeliver completion')
assert(S.nextFocus().ok and S.status().focus.phase == 'break')
now = 1300; wake()
assert(S.status().focus.nextPhase == 'focus')
assert(S.cancelFocus().ok and S.status().focus.state == 'idle')

-- Offline and overdue reminders are persisted as consumed before notification.
local reminder = S.add('Move the laundry', 2)
assert(reminder.ok and #S.list() == 1)
S.shutdown(); now = 1500; S = module.new(deps)
assert(#S.list() == 0 and #notifications == 3 and #notifications[3].state.reminders == 0)
S.shutdown(); S = module.new(deps); assert(#notifications == 3)
local r = S.add('Cancel me', 1); assert(S.cancel(r.id).ok and #S.list() == 0)
assert(not S.cancel(r.id).ok)

-- Failed saves do not claim success, change memory or send notifications.
failWrite = true
assert(not S.add('Cannot save', 1).ok and #S.list() == 0)
assert(not S.startFocus().ok and S.status().focus.state == 'idle')
failWrite = false
assert(S.startFocus({focusMinutes = 1}).ok)
now = 1600; failWrite = true; wake()
assert(S.status().focus.state == 'running' and #notifications == 3)
failWrite = false; wake()
assert(S.status().focus.state == 'awaiting_next' and #notifications == 4)

assert(not S.add('', 1).ok and not S.add('Too late', 10081).ok)
assert(not S.add('Line\nbreak', 1).ok and not S.startFocus({focusMinutes = 0}).ok)
S.setOnChange(function() error('UI failed') end)
assert(S.cancelFocus().ok)
local opened = false; S.setOpenCallback(function() opened = true end)
assert(S.add('Open settings', 1).ok); now = 1700; wake()
notifications[#notifications].click(); assert(opened)

-- Four completed focus rounds select the long break without auto-starting it.
for round = 1, 4 do
  if round == 1 then assert(S.startFocus({focusMinutes = 1, breakMinutes = 1, longBreakMinutes = 2}).ok)
  else assert(S.nextFocus().ok) end
  now = now + 60; wake()
  assert(S.status().focus.nextPhase == (round == 4 and 'long_break' or 'break'))
  if round < 4 then assert(S.nextFocus().ok); now = now + 60; wake() end
end
S.shutdown()
local corrupt = module.new(setmetatable({read = function() return {schema = 999} end}, {__index = deps}))
assert(not corrupt.add('Do not overwrite', 1).ok and corrupt.status().lastError ~= '')
corrupt.shutdown()

-- The pending queue is bounded and rejects unsupported option keys.
local clean = module.new(setmetatable({read = function() return nil end}, {__index = deps}))
for index = 1, 20 do assert(clean.add('Reminder ' .. index, 1).ok) end
assert(not clean.add('Overflow', 1).ok and #clean.list() == 20)
assert(not clean.startFocus({unexpected = 5}).ok)
clean.shutdown()

-- Backward clock changes cannot save a pause longer than the selected phase.
disk = nil; now = 10000
local clock = module.new(deps)
assert(clock.startFocus({focusMinutes = 180}).ok)
now = 6400
assert(clock.status().focus.remainingSeconds == 10800)
assert(clock.pauseFocus().ok and clock.status().focus.remainingSeconds == 10800)
clock.shutdown(); clock = module.new(deps)
assert(clock.status().lastError == '' and clock.status().focus.state == 'paused')
assert(clock.resumeFocus().ok and clock.status().focus.endsAt == 17200)
clock.shutdown()

-- Exercise the native notification adapter without files or system notifications.
local nativeDisk, encoded, delivered, registry = nil, nil, {}, {}
local nativeHS = {
  timer = {secondsSinceEpoch = deps.now, doAfter = deps.after},
  fs = {
    symlinkAttributes = function(path)
      if path:match('/Sessions$') or path:match('/LeanMac$') then return 'directory' end
      return nativeDisk and 'file' or nil
    end,
    attributes = function() return 'rwx------' end,
  },
  host = {uuid = function() return 'fixture' end},
  execute = function() return '', true end,
  json = {encode = function(value) encoded = copy(value); return 'fixture' end, decode = function() return copy(nativeDisk) end},
  caffeinate = {watcher = {new = function() return {start = function(self) return self end, stop = function() end} end}},
  notify = {
    activationTypes = {ContentsClicked = 1, ActionButtonClicked = 2},
    register = function(tag, callback) registry[tag] = callback; return 1 end,
    new = function(tag, attributes)
      local notification = {tag = tag, attributes = attributes}
      function notification:send() delivered[#delivered + 1] = self; return self end
      return notification
    end,
  },
}
local nativeEnv = setmetatable({hs = nativeHS,
  os = {getenv = function() return '/sandbox' end, rename = function() nativeDisk = copy(encoded); return true end, remove = function() return true end},
  io = {open = function() return {read = function() return 'fixture' end, write = function() return true end, close = function() return true end} end},
}, {__index = _G})
local nativeModule = assert(loadfile(KIT .. '/config/hangar-sessions.lua', 't', nativeEnv))()
local beforeReload, afterReload = 0, 0
local native = nativeModule.new(); native.setOpenCallback(function() beforeReload = beforeReload + 1 end)
assert(native.add('Adapter reminder', 1).ok); now = now + 60; native.status()
local note = delivered[1]
assert(type(note.tag) == 'string' and registry[note.tag], 'notification needs a stable registered tag')
assert(note.attributes.withdrawAfter == 0 and note.attributes.alwaysPresent == false)
native.shutdown()
native = nativeModule.new(); native.setOpenCallback(function() afterReload = afterReload + 1 end)
registry[note.tag]({activationType = function() return nativeHS.notify.activationTypes.ContentsClicked end})
assert(beforeReload == 0 and afterReload == 1, 'an old notification must open the current settings handler')
native.setOpenCallback(function() afterReload = afterReload + 10 end)
registry[note.tag]({activationType = function() return nativeHS.notify.activationTypes.ActionButtonClicked end})
assert(afterReload == 11)
native.shutdown()
print('Sessions persistence, focus and reminder checks passed')
