-- Receives secure-input-safe Carbon hotkeys from leanmac-hotkeys and owns
-- gestures that should not be global keyboard event taps.
local H = {}
local notificationName = 'local.leanmac.hotkeys'
local cli = hs.fs.attributes('/opt/homebrew/bin/aerospace') and '/opt/homebrew/bin/aerospace' or '/usr/local/bin/aerospace'
H.tasks = {}

local function aero(args)
  local task
  task = hs.task.new(cli, function(code, out, err)
    H.tasks[task] = nil
    if code ~= 0 then hs.printf('LeanMac gesture: %s', err or out) end
  end, args)
  if task then H.tasks[task] = true; task:start() end
end

local function picker()
  return package.loaded['window-picker'] or (leanmac and leanmac.picker)
end

local function snap()
  return package.loaded['window-snap'] or (leanmac and leanmac.snap)
end

local keymapLeft = [[
WINDOWS
⌥ Tab            exact-window picker
⌥ ⇧ Tab          picker backwards
⌥ H/J/K/L        focus left/down/up/right
⌥ ⇧ H/J/K/L      move window
⌥ ← / →          snap left / right
⌥ ↑ / ↓          maximize / restore

WORKSPACES
⌥ 1…4            switch workspace
⌥ ⇧ 1…4          move window to workspace
⌥ `              previous workspace
MX gesture ←/→   previous / next workspace
3-finger ←/→     next / previous workspace
]]

local keymapRight = [[
MONITORS
⌥ , / .          focus previous / next monitor
⌥ ⇧ , / .        move window to monitor

LAYOUT
⌥ F              fullscreen
⌥ ⇧ Space        float / tile
⌥ /              reset tiled layout
⌃ ⌥ ?            reset accordion layout
⌥ - / =          shrink / grow
⌥ ⇧ =            balance sizes
⌥ ⇧ R            reload AeroSpace

HELP
⌥ ?              toggle this keymap
]]

local function hideKeymap()
  if H.keymapTimer then H.keymapTimer:stop(); H.keymapTimer = nil end
  if H.keymapCanvas then H.keymapCanvas:hide() end
  H.keymapVisible = false
end

local function showKeymap()
  if H.keymapVisible then hideKeymap(); return end
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local sf = screen:frame()
  local width, height = math.min(900, sf.w - 80), math.min(590, sf.h - 80)
  local frame = {x = sf.x + (sf.w - width) / 2, y = sf.y + (sf.h - height) / 2,
    w = width, h = height}
  if H.keymapCanvas then H.keymapCanvas:delete() end
  H.keymapCanvas = hs.canvas.new(frame):level(hs.canvas.windowLevels.overlay)
  H.keymapCanvas:behavior({hs.canvas.windowBehaviors.canJoinAllSpaces,
    hs.canvas.windowBehaviors.stationary})
  H.keymapCanvas[1] = {type='rectangle', action='fill',
    fillColor={hex='#111318', alpha=0.96}, roundedRectRadii={xRadius=18, yRadius=18}}
  H.keymapCanvas[2] = {type='rectangle', action='stroke',
    strokeColor={hex='#6b8cff', alpha=0.8}, strokeWidth=2,
    roundedRectRadii={xRadius=18, yRadius=18}}
  H.keymapCanvas[3] = {type='text', text='LeanMac · AeroSpace keymap',
    frame={x=32, y=22, w=width-64, h=42}, textSize=25,
    textColor={hex='#f4f6ff'}, textFont='SF Pro Display'}
  H.keymapCanvas[4] = {type='text', text=keymapLeft,
    frame={x=38, y=76, w=(width-90)/2, h=height-120}, textSize=16,
    textColor={hex='#d9def0'}, textFont='SF Mono'}
  H.keymapCanvas[5] = {type='text', text=keymapRight,
    frame={x=52+(width-90)/2, y=76, w=(width-90)/2, h=height-120}, textSize=16,
    textColor={hex='#d9def0'}, textFont='SF Mono'}
  H.keymapCanvas[6] = {type='text', text='⌥? or click to close · hides automatically',
    frame={x=32, y=height-42, w=width-64, h=24}, textSize=13,
    textColor={hex='#8f98b3'}, textAlignment='center'}
  H.keymapCanvas:canvasMouseEvents(true, true, false, false)
  H.keymapCanvas:mouseCallback(function() hideKeymap() end)
  H.keymapCanvas:show()
  H.keymapVisible = true
  H.keymapTimer = hs.timer.doAfter(12, hideKeymap)
end

local function dispatch(action)
  local P, S = picker(), snap()
  if action == 'picker-forward' and P then P.start(true, false, true)
  elseif action == 'picker-backward' and P then P.start(true, true, true)
  elseif action == 'picker-search' and P then P.start(false, false, true)
  elseif action == 'picker-confirm' and P then P.confirm()
  elseif action == 'snap-left' and S then S.apply(hs.window.focusedWindow(), 'left')
  elseif action == 'snap-right' and S then S.apply(hs.window.focusedWindow(), 'right')
  elseif action == 'snap-up' and S then S.apply(hs.window.focusedWindow(), 'up')
  elseif action == 'snap-down' and S then S.apply(hs.window.focusedWindow(), 'down')
  elseif action == 'keymap' then showKeymap()
  end
end

H.notification = hs.distributednotifications.new(function(_, object, userInfo)
  local action = object or (userInfo and userInfo.action)
  if action then dispatch(action) end
end, notificationName):start()

-- Three fingers move through AeroSpace workspaces on the monitor beneath the
-- pointer. Two-finger scrolling and vertical three/four-finger macOS gestures
-- are untouched. Native horizontal three-finger Spaces must be disabled.
H.touches, H.swipe = {}, nil
local function centroid()
  local x, y, count = 0, 0, 0
  for _, touch in pairs(H.touches) do
    if touch.touching then
      x, y, count = x + touch.x, y + touch.y, count + 1
    end
  end
  if count == 0 then return nil, nil, 0 end
  return x / count, y / count, count
end

local function finishSwipe()
  local swipe = H.swipe
  H.swipe = nil
  if not swipe or swipe.cancelled or not swipe.lastX then return end
  local dx, dy = swipe.lastX - swipe.startX, swipe.lastY - swipe.startY
  local elapsed = hs.timer.secondsSinceEpoch() - swipe.startedAt
  if elapsed > 1.6 or math.abs(dx) < 0.11 or math.abs(dx) < math.abs(dy) * 1.25 then return end
  if H.lastSwipeAt and hs.timer.secondsSinceEpoch() - H.lastSwipeAt < 0.35 then return end
  H.lastSwipeAt = hs.timer.secondsSinceEpoch()
  local direction = dx < 0 and 'next' or 'prev'
  H.lastSwipe = {direction=direction, dx=dx, dy=dy, elapsed=elapsed,
    at=H.lastSwipeAt}
  local expression = 'list-workspaces --monitor mouse --visible | workspace --stdin next; workspace ' .. direction .. ' --wrap-around'
  aero({'eval', expression})
end

H.trackpad = hs.eventtap.new({hs.eventtap.event.types.gesture}, function(event)
  local touches = event:getTouches()
  if type(touches) ~= 'table' then return false end
  for _, touch in ipairs(touches) do
    if touch.type == 'indirect' and not touch.resting and touch.normalizedPosition then
      if touch.touching then
        H.touches[touch.identity] = {touching=true,
          x=touch.normalizedPosition.x, y=touch.normalizedPosition.y}
      else
        H.touches[touch.identity] = nil
      end
    end
  end
  local x, y, count = centroid()
  if count == 3 then
    if not H.swipe then
      H.swipe = {startX=x, startY=y, lastX=x, lastY=y,
        startedAt=hs.timer.secondsSinceEpoch()}
    else
      H.swipe.lastX, H.swipe.lastY = x, y
    end
  elseif count > 3 then
    if H.swipe then H.swipe.cancelled = true end
  elseif H.swipe then
    finishSwipe()
  end
  return false
end):start()

H.dispatch = dispatch
H.showKeymap = showKeymap
return H
