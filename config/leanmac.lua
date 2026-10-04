-- LeanMac: AeroSpace owns windows; Hammerspoon owns utility shortcuts.
local M = {version = '2026.09.17.2'}
local mods = {'ctrl', 'alt', 'cmd'}
local cli = hs.fs.attributes('/opt/homebrew/bin/aerospace') and '/opt/homebrew/bin/aerospace' or '/usr/local/bin/aerospace'
M.tasks = {}
local function aero(args)
  local task
  task = hs.task.new(cli, function(code, out, err)
    M.tasks[task] = nil
    if code ~= 0 then hs.printf('LeanMac AeroSpace: %s', err or out) end
  end, args)
  if task then M.tasks[task] = true; task:start() end
end
hs.hotkey.bind(mods, 'return', function() hs.application.launchOrFocus('Ghostty') end)
hs.hotkey.bind(mods, 'b', function() hs.application.launchOrFocus('Brave Browser') end)
hs.hotkey.bind(mods, 'e', function() hs.application.launchOrFocus('Finder') end)
hs.hotkey.bind(mods, 'm', function() hs.urlevent.openURL('thaw://toggle-thawbar') end)
hs.hotkey.bind(mods, 'p', function() hs.urlevent.openURL('thaw://search') end)
hs.hotkey.bind(mods, 'r', hs.reload)
hs.hotkey.bind(mods, 'escape', function() aero({'enable', 'toggle'}) end)
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
