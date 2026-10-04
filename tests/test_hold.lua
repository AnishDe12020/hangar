-- The fake replaces only native processes; exercise the real session lifecycle.
local now, tasks, failStart, failNew = 1000, {}, false, false
local env = {hs = {processInfo = {processID = 42}, timer = {secondsSinceEpoch = function() return now end}, task = {}}}
function env.hs.task.new(path, callback, args)
  if failNew then return nil end
  local t = {path = path, callback = callback, args = args, running = false, terminated = false}
  function t:start() if failStart then return false end; self.running = true; return self end
  function t:isRunning() return self.running end
  function t:terminate() if self.failTerminate then error('denied') end; self.terminated = true; return self end
  function t:finish(code, err) self.running = false; self.callback(code or 0, '', err or '') end
  tasks[#tasks + 1] = t
  return t
end
setmetatable(env, {__index = _G})
local source = io.open(KIT .. '/config/hangar-hold.lua')
assert(source, 'Holding Pattern module is missing'); source:close()
local H = assert(loadfile(KIT .. '/config/hangar-hold.lua', 't', env))()
local notices = {}
H.setOnChange(function(state) notices[#notices + 1] = state end)

assert(not H.status().active and H.status().remainingSeconds == 0)
local first = H.start(15)
assert(first.ok and first.active and not first.display and first.endsAt == 1900)
assert(notices[#notices].active)
assert(tasks[1].path == '/usr/bin/caffeinate')
assert(table.concat(tasks[1].args, ' ') == '-i -t 900 -w 42')
now = 1010
assert(H.status().remainingSeconds == 890)

-- Invalid input never terminates the existing hold or launches a process.
for _, minutes in ipairs({0, -1, 1441, 1.5, '15', math.huge}) do
  assert(not H.start(minutes).ok and H.status().active and not tasks[1].terminated)
end
assert(not H.start(15, 'yes').ok and #tasks == 1)
failStart = true
assert(not H.start(30).ok and not tasks[1].terminated)
failStart = false; failNew = true
assert(not H.start(30).ok and not tasks[1].terminated)
failNew = false

-- Delayed completion from the replaced session must not clear its successor.
assert(H.start(30, true).ok)
local second = tasks[#tasks]
assert(table.concat(second.args, ' ') == '-i -d -t 1800 -w 42')
assert(tasks[1].terminated and H.status().display)
tasks[1]:finish(15)
assert(H.status().active and H.status().endsAt == 2810 and H.status().lastError == '')
second:finish(1, 'permission denied')
assert(not H.status().active and H.status().lastError:find('permission denied', 1, true))
assert(not notices[#notices].active and notices[#notices].lastError ~= '')

-- SIGTERM is asynchronous: report pending stop, keep ownership, then clear.
assert(H.start(1).ok)
local third = tasks[#tasks]
local stop = H.stop()
assert(stop.ok and stop.active and stop.stopping and third.terminated)
third:finish(15)
assert(not H.status().active and H.status().lastError == '')
assert(not notices[#notices].active)
assert(H.stop().ok and not H.status().active)

-- A termination failure retains the handle so stop can be retried.
assert(H.start(1440).ok)
local fourth = tasks[#tasks]; fourth.failTerminate = true
assert(table.concat(fourth.args, ' ') == '-i -t 86400 -w 42')
assert(not H.shutdown().ok and H.status().active and H.status().lastError ~= '')
fourth.failTerminate = false
assert(H.shutdown().ok); fourth:finish(15)
assert(not H.status().active)

-- A task whose exit callback has not yet run is not advertised as alive.
H.setOnChange(function() error('broken UI callback') end)
assert(H.start(1).ok)
tasks[#tasks].running = false
assert(not H.status().active and H.status().remainingSeconds == 0)
tasks[#tasks]:finish(0)
print('Holding Pattern lifecycle checks passed')
