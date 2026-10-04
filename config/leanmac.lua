local U = require('hangar-config')
-- Hangar: AeroSpace owns windows; Hammerspoon owns utility shortcuts.
local M = {version = '2026.10.04.3'}
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
return M
