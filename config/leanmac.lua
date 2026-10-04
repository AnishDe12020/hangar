local U = require('hangar-config')
-- Hangar: AeroSpace owns windows; Hammerspoon owns utility shortcuts.
local M = {version = '2026.10.05.1'}
local cli = hs.fs.attributes('/opt/homebrew/bin/aerospace') and '/opt/homebrew/bin/aerospace' or '/usr/local/bin/aerospace'
M.tasks = {}
local function aero(args)
  local task
  task = hs.task.new(cli, function(code, out, err)
    M.tasks[task] = nil
    if code ~= 0 then hs.printf('Hangar AeroSpace: %s', err or out) end
  end, args)
  if task then M.tasks[task] = true; task:start() end
end
U.bind('terminal', function() hs.application.launchOrFocus(U.apps.terminal) end)
U.bind('browser', function() hs.application.launchOrFocus(U.apps.browser) end)
U.bind('finder', function() hs.application.launchOrFocus(U.apps.finder) end)
U.bind('menu_bar', function() hs.urlevent.openURL('thaw://toggle-thawbar') end)
U.bind('menu_search', function() hs.urlevent.openURL('thaw://search') end)
U.bind('reload', hs.reload)
U.bind('management_toggle', function() aero({'enable', 'toggle'}) end)
hs.autoLaunch(true)
require('hs.ipc')
M.picker = require("window-picker")
M.groups = require("window-groups")
M.overview = require("workspace-overview")
M.spaces = require("spaces-sync")
M.snap = require("window-snap")
M.mx = require("mx-buttons")
M.health = require("leanmac-health")
M.palette = require("leanmac-palette")
function M.openUtility(kind)
  if kind == 'shelf' and U.modules and U.modules.shelf == false then
    hs.alert.show('Apron is disabled in Hangar settings'); return
  end
  local bundle = kind == 'shelf' and 'HangarShelf.app' or 'HangarSettings.app'
  local program = kind == 'shelf' and hs.configdir .. '/bin/HangarShelf.app/Contents/MacOS/hangar-shelf' or '/usr/bin/open'
  local arguments = kind == 'shelf' and {'--wait', '--style', U.shelf_style or 'compact'} or {hs.configdir .. '/bin/' .. bundle}
  local task
  task = hs.task.new(program, function(code, out, err)
    M.tasks[task] = nil
    if code ~= 0 then hs.alert.show('Could not open ' .. bundle); hs.printf('Hangar: %s', err or out) end
  end, arguments)
  if task then M.tasks[task] = true; task:start() end
end
M.settingsKey = U.bind('settings', function() M.openUtility('settings') end)
if not U.modules or U.modules.shelf ~= false then
  M.shelfKey = U.bind('shelf', function() M.openUtility('shelf') end)
end
-- Apron's event-driven drag observer has no polling timer. Its private inbox
-- makes this safe across reloads: background never summons another window.
local shelfTask
shelfTask = hs.task.new(hs.configdir .. '/bin/HangarShelf.app/Contents/MacOS/hangar-shelf', function(code, out, err)
  M.tasks[shelfTask] = nil
  if code ~= 0 then hs.printf('Hangar Apron: %s', err or out) end
end, {U.modules and U.modules.shelf == false and '--quit' or '--background', '--style', U.shelf_style or 'compact'})
if shelfTask then M.tasks[shelfTask] = true; shelfTask:start() end
return M
