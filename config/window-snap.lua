-- Float-and-place snap. AeroSpace keeps tiling until we explicitly float.
local S = {}
local cli = hs.fs.attributes('/opt/homebrew/bin/aerospace') and '/opt/homebrew/bin/aerospace' or '/usr/local/bin/aerospace'
local gap, restore, tasks = 8, {}, {}
local function aero(args, cb)
  local task
  task = hs.task.new(cli, function(code, out, err)
    tasks[task] = nil
    if code ~= 0 then hs.printf('Hangar snap: %s', err or out) end
    if cb then cb(code == 0) end
  end, args)
  if task then tasks[task] = true; task:start() end
end
local function usable(screen)
  local f = screen:frame()
  return {x = f.x + gap, y = f.y + gap, w = f.w - 2 * gap, h = f.h - 2 * gap}
end
local function zoneFrame(screen, zone)
  local u = usable(screen)
  local halfW, halfH = math.floor((u.w - gap) / 2), math.floor((u.h - gap) / 2)
  if zone == 'left' then return {x = u.x, y = u.y, w = halfW, h = u.h} end
  if zone == 'right' then return {x = u.x + halfW + gap, y = u.y, w = u.w - halfW - gap, h = u.h} end
  if zone == 'up' then return u end
  local w, h = math.floor(u.w * 0.7), math.floor(u.h * 0.7)
  return {x = u.x + math.floor((u.w - w) / 2), y = u.y + math.floor((u.h - h) / 2), w = w, h = h}
end
local function remember(win)
  local id = win:id()
  if id and not restore[id] then restore[id] = win:frame() end
end
function S.apply(win, zone)
  if not win or not win:isStandard() or win:isFullScreen() then return end
  remember(win)
  local id = win:id()
  local screen = win:screen()
  local frame
  if zone == 'down' and id and restore[id] then
    frame = restore[id]
    restore[id] = nil
  else
    frame = zoneFrame(screen, zone)
  end
  aero({'layout', 'floating'}, function()
    hs.timer.doAfter(0.08, function()
      local current = id and hs.window.get(id) or win
      if current then current:setFrame(frame, 0) end
    end)
  end)
end
local function focused(zone)
  return function() S.apply(hs.window.focusedWindow(), zone) end
end
S.left = hs.hotkey.bind({'alt'}, 'left', focused('left'))
S.right = hs.hotkey.bind({'alt'}, 'right', focused('right'))
S.up = hs.hotkey.bind({'alt'}, 'up', focused('up'))
S.down = hs.hotkey.bind({'alt'}, 'down', focused('down'))

local drag, preview = {}, nil
local function hidePreview()
  if preview then preview:hide() end
end
local function showPreview(screen, zone)
  local frame = zoneFrame(screen, zone)
  if not preview then
    preview = hs.canvas.new(frame):level(hs.canvas.windowLevels.overlay)
    preview[1] = {type = 'rectangle', action = 'fill',
      fillColor = {red = 0.25, green = 0.55, blue = 1, alpha = 0.22},
      roundedRectRadii = {xRadius = 14, yRadius = 14}}
    preview[2] = {type = 'rectangle', action = 'stroke',
      strokeColor = {red = 0.45, green = 0.7, blue = 1, alpha = 0.8}, strokeWidth = 2,
      roundedRectRadii = {xRadius = 14, yRadius = 14}}
  end
  preview:frame(frame):show()
end
local function edgeZone(screen, pos)
  local f = screen:frame()
  local margin = 28
  if pos.y <= f.y + margin then return 'up' end
  if pos.x <= f.x + margin then return 'left' end
  if pos.x >= f.x + f.w - margin then return 'right' end
  return nil
end
local function inTitlebar(win, pos)
  local f = win:frame()
  return pos.x >= f.x and pos.x <= f.x + f.w and pos.y >= f.y and pos.y <= f.y + 48
end
S.mouse = hs.eventtap.new({
  hs.eventtap.event.types.leftMouseDown,
  hs.eventtap.event.types.leftMouseDragged,
  hs.eventtap.event.types.leftMouseUp
}, function(e)
  local t, pos = e:getType(), hs.mouse.absolutePosition()
  if t == hs.eventtap.event.types.leftMouseDown then
    local win = hs.window.focusedWindow()
    drag = {win = win, fromTitle = win and win:isStandard() and inTitlebar(win, pos), start = pos, zone = nil}
    return false
  end
  if t == hs.eventtap.event.types.leftMouseDragged then
    if not drag.fromTitle or not drag.win then return false end
    local dx, dy = pos.x - drag.start.x, pos.y - drag.start.y
    if (dx * dx + dy * dy) < 64 then return false end
    local screen = hs.mouse.getCurrentScreen() or drag.win:screen()
    local zone = edgeZone(screen, pos)
    drag.zone, drag.screen = zone, screen
    if zone then showPreview(screen, zone) else hidePreview() end
    return false
  end
  hidePreview()
  local win, zone = drag.win, drag.zone
  drag = {}
  if win and zone then S.apply(win, zone) end
  return false
end):start()
return S
