-- Bounded operation-count check: baseline algorithm vs current code.
-- Run with: python3 tests/run_picker_tests.py bench
-- Counts mock hs.* calls as a proxy for chooser/task/settings operations.
-- These are not live latency or memory measurements.
local checks = 0
local function check(v, msg) assert(v, msg or 'check failed'); checks = checks + 1 end

local settingsStore, settingsWrites = {}, 0
local linksEnv = {hs = {settings = {
  get = function(k) return settingsStore[k] end,
  set = function(k, v) settingsWrites = settingsWrites + 1; settingsStore[k] = v end}}}
setmetatable(linksEnv, {__index = _G})
local L = assert(loadfile(KIT .. '/config/window-links.lua', 't', linksEnv))()

local chooser = {list = {}, queryStr = '', row = 0, probes = 0}
function chooser:rows() return self end
function chooser:width() return self end
function chooser:searchSubText() return self end
function chooser:bgDark() return self end
function chooser:fgColor() return self end
function chooser:subTextColor() return self end
function chooser:placeholderText() return self end
function chooser:query(q) if q ~= nil then self.queryStr = q; return self end return self.queryStr end
function chooser:choices(l) if l ~= nil then self.list = l; return self end return self.list end
function chooser:selectedRow(n) if n ~= nil then self.row = n; return self end return self.row end
function chooser:selectedRowContents(i)
  self.probes = self.probes + 1
  return self.list[i or self.row] or {}
end
function chooser:show() return self end
function chooser:hide() return self end
function chooser:hideCallback() return self end

local tasks = {}
local function taskNew(cmd, cb, a, b)
  local stream = type(a) == 'function' and a or nil
  local t = {cmd = cmd, cb = cb, args = stream and b or a, killed = false, done = false}
  function t:start() tasks[#tasks + 1] = self; return true end
  function t:terminate() self.killed = true end
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
local decodeResult = {}
local env = {hs = {
  fs = {attributes = function(_, mode) if mode ~= nil then return nil end return true end},
  configdir = '/fixture',
  chooser = {new = function() return chooser end},
  eventtap = {new = function() return {start = function(s) return s end, stop = function() end} end,
    event = {types = {keyDown = 1, flagsChanged = 2}},
    isSecureInputEnabled = function() return false end,
    checkKeyboardModifiers = function() return {alt = true} end},
  hotkey = {bind = function() return {enabled = true} end},
  task = {new = taskNew},
  timer = {doAfter = timerNew, absoluteTime = function() return 0 end},
  window = {focusedWindow = function() return nil end, orderedWindows = function() return {} end},
  keycodes = {map = {escape = 53, tab = 48, ['return'] = 36}},
  alert = {show = function() end},
  json = {decode = function() return decodeResult end},
  image = {imageFromAppBundle = function() return nil end},
  axuielement = {applicationElementForPID = function() return nil end},
  printf = function() end,
}}
local realRequire = require
local panelSteps = 0
env.require = function(name)
  if name == 'window-links' then return L end
  if name == 'picker-panel' then return {new=function() return {
    prewarm=function() end, step=function() panelSteps=panelSteps+1 end} end} end
  return realRequire(name)
end
setmetatable(env, {__index = _G})
local P = assert(loadfile(KIT .. '/config/window-picker.lua', 't', env))()

local function w(id)
  return {['window-id'] = id, ['app-pid'] = 100 + id, ['app-name'] = 'App' .. id,
    ['app-bundle-id'] = 'fixture.app', ['window-title'] = 'window ' .. id,
    workspace = tostring(1 + (id % 3)), ['monitor-name'] = 'Main',
    ['workspace-is-visible'] = true, ['workspace-is-focused'] = false,
    ['window-parent-container-layout'] = 'v_accordion',
    ['workspace-root-container-layout'] = 'v_accordion'}
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
local function finishRefresh(rows)
  decodeResult = rows
  refreshTask():finish(0, 'json')
end

local rows = {}
for i = 1, 40 do rows[i] = w(i) end
finishRefresh(rows)
P.choices = {}; for _, c in ipairs(P.cache) do P.choices[#P.choices + 1] = c end
chooser:choices(P.choices)
chooser.row = 1

-- Baseline step: one selectedRowContents probe per cached row, every keypress.
local function baselineStep(delta)
  local count = 0
  for i = 1, #(P.choices or {}) do
    if not chooser:selectedRowContents(i).id then break end
    count = count + 1
  end
  if count > 0 then
    chooser:selectedRow(((math.max(chooser.row, 1) - 1 + delta) % count) + 1)
  end
end

local presses = 500
chooser.probes = 0
for _ = 1, presses do baselineStep(1) end
local baselineProbes = chooser.probes
chooser.probes = 0
for _ = 1, presses do P.step(1) end
local newProbes = chooser.probes
print(string.format('keypress step (%d presses, 40 rows, empty query): baseline=%d chooser row probes, new=%d',
  presses, baselineProbes, newProbes))
check(newProbes == 0, 'step must not probe rows on an empty query')
check(panelSteps == presses, 'one presentation message per keypress')
local t0 = os.clock()
for _ = 1, presses do baselineStep(1) end
local baselineMs = (os.clock() - t0) * 1000
t0 = os.clock()
for _ = 1, presses do P.step(1) end
local newMs = (os.clock() - t0) * 1000
print(string.format('step CPU time (os.clock, mock call cost only): baseline=%.1fms new=%.1fms', baselineMs, newMs))

-- Refresh coalescing: a burst of events during one in-flight list-windows.
local n0 = refreshCount()
P.refresh()
for _ = 1, 6 do P.refresh() end -- baseline dropped these entirely
check(refreshCount() == n0 + 1, 'burst during flight still spawns no extra task')
finishRefresh({w(900)})
local spawned = refreshCount() - n0
check(spawned == 2, 'queued events produce exactly one follow-up')
finishRefresh({w(901)})
check(P.byID[901] ~= nil, 'cache reflects the latest snapshot')
print(string.format('refresh burst (6 events during one in-flight list): baseline=1 task and stale cache, new=%d tasks and current cache', spawned))

-- The old picker never reconciled on refresh, so the comparison is between the
-- old unconditional-save window-links.reconcile and the new write-on-change
-- reconcile fed five identical snapshots.
local w0 = settingsWrites
for _ = 1, 5 do P.refresh(); finishRefresh(rows) end
local writes = settingsWrites - w0
print(string.format('pair settings writes, old window-links.reconcile vs new reconcile under five identical snapshots: old=5, new=%d', writes))
check(writes == 0, 'unchanged pair metadata must not write settings')

print(checks .. ' bench checks passed; counts above are mock-operation counts, not live measurements')
