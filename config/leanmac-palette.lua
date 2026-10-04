local R = require('leanmac-runtime')
local C = {choices = {}, actions = {}}
local focusHelper = hs.configdir .. '/bin/leanmac-window-focus'

local function captureOrigin()
  local win = hs.window.focusedWindow()
  if not win then return nil end
  local origin = {id = win:id(), pid = win:pid(), restores = {}}
  local seen, screen = {}, win:screen()
  for _, other in ipairs(hs.window.orderedWindows()) do
    local otherScreen = other:screen()
    local uuid = otherScreen and otherScreen:getUUID()
    if otherScreen and otherScreen ~= screen and not seen[uuid] then
      local cached = leanmac.picker.byID and leanmac.picker.byID[other:id()]
      if cached and cached.visible then
        local space = hs.spaces.activeSpaceOnScreen(otherScreen)
        if space then
          table.insert(origin.restores, tostring(space))
          table.insert(origin.restores, tostring(other:pid()))
          seen[uuid] = true
        end
      end
    end
  end
  return origin
end

local function restoreOrigin(origin, done)
  if not origin then done(); return end
  local win = hs.window.get(origin.id)
  if not win then hs.alert.show('Original window closed; command cancelled'); return end
  local args = {tostring(origin.pid), tostring(origin.id)}
  for _, value in ipairs(origin.restores) do table.insert(args, value) end
  R.run(focusHelper, args, function(code, _, err)
    if code ~= 0 then hs.alert.show('Could not restore the original window'); hs.printf('Hangar palette: %s', err); return end
    win:raise()
    hs.timer.doAfter(0.08, done)
  end)
end

local function add(choices, actions, id, title, detail, fn)
  table.insert(choices, {id = id, text = title, subText = detail})
  actions[id] = fn
end

local function commandTitle(command)
  local workspace = command:match('^workspace ([%w_-]+)$')
  if workspace then return 'Switch to workspace ' .. workspace end
  workspace = command:match('^move%-node%-to%-workspace ([%w_-]+)$')
  if workspace then return 'Move window to workspace ' .. workspace end
  local names = {
    ['workspace-back-and-forth'] = 'Return to previous workspace',
    ['workspace --wrap-around prev'] = 'Previous workspace',
    ['workspace --wrap-around next'] = 'Next workspace',
    ['focus-monitor --wrap-around prev'] = 'Focus previous monitor',
    ['focus-monitor --wrap-around next'] = 'Focus next monitor',
    ['move-node-to-monitor --focus-follows-window --wrap-around prev'] = 'Move window to previous monitor',
    ['move-node-to-monitor --focus-follows-window --wrap-around next'] = 'Move window to next monitor',
    ['fullscreen'] = 'Toggle full-display window', ['layout floating tiling'] = 'Toggle floating / tiled',
    ['resize smart -50'] = 'Shrink window', ['resize smart +50'] = 'Grow window',
    ['balance-sizes'] = 'Balance window sizes', ['reload-config'] = 'Reload AeroSpace config',
    ['layout tiles'] = 'Tile this group (keep pairs)', ['layout accordion'] = 'Stack this group (keep pairs)',
  }
  if names[command] then return names[command] end
  if command:find('layout') and command:find('accordion') then return 'Reset to accordion layout' end
  if command:find('layout') and command:find('tiles') then return 'Reset to tiled layout' end
  if command:match('^move ') then return command:gsub('^move ', 'Move window ') end
  return command:gsub('^%l', string.upper)
end

function C.refresh()
  R.run(R.aerospace, {'config', '--get', 'mode.main.binding', '--json'}, function(code, out)
    local ok, bindings = pcall(hs.json.decode, out)
    if code ~= 0 or not ok or type(bindings) ~= 'table' then return end
    local choices, actions = {}, {}
    add(choices, actions, 'doctor', 'Diagnose Hangar', 'Secure Input · services · displays · shortcuts', C.diagnose)
    add(choices, actions, 'windows', 'Search windows', '⌃⌥⌘W · exact window picker', function() leanmac.picker.start(false, false) end)
    add(choices, actions, 'layouts', 'Window layouts', '⌥G · split pairs, zoom, resize and reset', function() leanmac.groups.show() end)
    add(choices, actions, 'overview', 'Workspace overview', '⌥O · drag windows and linked pairs between spaces', function() leanmac.overview.show() end)
    add(choices, actions, 'pair', 'Pair with another window…', '⌥P · same-space window chooser', function() leanmac.groups.choose() end)
    add(choices, actions, 'separate', 'Separate this window', '⌥⇧P · return to a standalone view', function() leanmac.groups.separate() end)
    add(choices, actions, 'hs-reload', 'Reload Hammerspoon', '⌃⌥⌘R · reload utility config', hs.reload)
    add(choices, actions, 'gather', 'Gather windows from extra macOS Desktops…', '⌃⌥⌘S · moves windows; does not delete Desktops', function()
      leanmac.spaces.collapseNow()
    end)
    for _, zone in ipairs({'left', 'right', 'up', 'down'}) do
      local z = zone
      local names = {left = 'Snap left half', right = 'Snap right half', up = 'Snap full display', down = 'Restore pre-snap frame'}
      add(choices, actions, 'snap-' .. z, names[z], '⌥ ' .. z .. ' arrow', function() leanmac.snap.apply(hs.window.focusedWindow(), z) end)
    end
    local keys = {}
    for key in pairs(bindings) do table.insert(keys, key) end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local binding = key
      local command = type(bindings[key]) == 'table' and table.concat(bindings[key], '; ') or tostring(bindings[key])
      local label = binding:gsub('alt', '⌥'):gsub('ctrl', '⌃'):gsub('cmd', '⌘'):gsub('shift', '⇧'):gsub('-', ' ')
      add(choices, actions, 'aero-' .. binding, commandTitle(command), label .. ' · AeroSpace', function()
        R.run(R.aerospace, {'trigger-binding', binding, '--mode', 'main'}, function(status, _, err)
          if status ~= 0 then hs.alert.show('AeroSpace: ' .. err) end
        end)
      end)
    end
    C.choices, C.actions = choices, actions
  end)
end

C.chooser = hs.chooser.new(function(choice)
  local origin, action = C.origin, choice and C.visibleActions[choice.id]
  hs.timer.doAfter(0.12, function() restoreOrigin(origin, action or function() end) end)
end):rows(12):width(65):searchSubText(true):placeholderText('Hangar · search a command or shortcut')
C.reportChooser = hs.chooser.new(function()
  local origin = C.origin
  hs.timer.doAfter(0.12, function() restoreOrigin(origin, function() end) end)
end):rows(12):width(70):searchSubText(true):placeholderText('Hangar doctor · read-only report · Escape to close')
function C.diagnose()
  R.run(R.cli, {'doctor', '--json'}, function(_, out, err)
    local ok, report = pcall(hs.json.decode, out)
    if not ok or not report.checks then hs.alert.show('Doctor failed: ' .. err); return end
    local rows = {}
    for _, check in ipairs(report.checks) do
      table.insert(rows, {text = check.status:upper() .. ' · ' .. check.name,
        subText = check.message, valid = false, rank = check.status == 'fail' and 0 or check.status == 'warn' and 1 or 2})
    end
    table.sort(rows, function(a, b) if a.rank ~= b.rank then return a.rank < b.rank end; return a.text < b.text end)
    C.reportChooser:query(''):choices(rows):show()
  end, 18)
end
local previousChooserCallback = hs.chooser.globalCallback
hs.chooser.globalCallback = function(chooser, event)
  if chooser ~= C.chooser and chooser ~= C.reportChooser and previousChooserCallback then previousChooserCallback(chooser, event) end
end

function C.show()
  if C.chooser:isVisible() then C.chooser:hide(); return end
  C.origin = captureOrigin()
  C.visibleActions = C.actions
  C.chooser:query(''):choices(C.choices):show()
  C.refresh() -- refresh the next opening without moving rows under the user
end
C.hotkey = hs.hotkey.bind({'ctrl', 'alt', 'cmd'}, '/', C.show)
assert(C.hotkey and C.hotkey.enabled, 'Hangar palette shortcut could not be registered')
C.refresh()
return C
