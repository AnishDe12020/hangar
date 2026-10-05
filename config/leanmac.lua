local U = require('hangar-config')
-- Hangar: AeroSpace owns windows; Hammerspoon owns utility shortcuts.
local M = {version = '2026.10.05.4'}
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
M.hold = require("hangar-hold")
M.sessions = require("hangar-sessions").new()
local function sessionAction(action)
  local result = action()
  if not result.ok then hs.alert.show(result.error or 'Session could not be updated') end
end
function M.quickReminder(minutes)
  local button, value = hs.dialog.textPrompt('Boarding Call', 'Remind me in ' .. minutes .. ' minutes:', '', 'Add Reminder', 'Cancel')
  if button == 'Add Reminder' then sessionAction(function() return M.sessions.add(value, minutes) end) end
end
local function updateHoldMenu()
  local status = M.hold.status()
  local sessions = M.sessions.status()
  if not M.holdMenu then
    local item = hs.menubar.new()
    if not item then hs.printf('Hangar: menu bar item unavailable'); return end
    M.holdMenu = item:setTitle('✈︎'):setTooltip('Hangar')
    M.holdMenu:setMenu(function()
      local current = M.hold.status()
      local sessions = M.sessions.status()
      local minutes = math.max(1, math.ceil(current.remainingSeconds / 60))
      local items = {
        {title = 'Open Apron', disabled = U.modules and U.modules.shelf == false, fn = function() M.openUtility('shelf') end},
        {title = 'Search Windows', fn = function() M.picker.start(false, false) end},
        {title = 'Workspace Overview', fn = function() M.overview.show() end},
        {title = 'Command Palette', fn = function() M.palette.show() end},
        {title = '-'},
      }
      local focus = sessions.focus
      if focus.state == 'idle' then
        table.insert(items, {title = 'Start 25-minute Focus', fn = function() sessionAction(function() return M.sessions.startFocus({}) end) end})
      else
        local phase = focus.phase == 'focus' and 'Focus' or focus.phase == 'long_break' and 'Long break' or 'Break'
        local focusMinutes = math.max(0, math.ceil(focus.remainingSeconds / 60))
        table.insert(items, {title = 'Turnaround · ' .. phase .. (focus.state == 'awaiting_next' and ' complete' or (' · ' .. focusMinutes .. ' min left')), disabled = true})
        if focus.state == 'running' then
          table.insert(items, {title = 'Pause Timer', fn = function() sessionAction(M.sessions.pauseFocus) end})
        elseif focus.state == 'paused' then
          table.insert(items, {title = 'Resume Timer', fn = function() sessionAction(M.sessions.resumeFocus) end})
        elseif focus.state == 'awaiting_next' then
          local nextPhase = focus.nextPhase == 'focus' and 'Focus' or focus.nextPhase == 'long_break' and 'Long Break' or 'Break'
          table.insert(items, {title = 'Start ' .. nextPhase, fn = function() sessionAction(M.sessions.nextFocus) end})
        end
        table.insert(items, {title = 'End Focus Session', fn = function() sessionAction(M.sessions.cancelFocus) end})
      end
      local reminders = {}
      for _, duration in ipairs({5, 15, 30, 60}) do
        local minutes = duration
        table.insert(reminders, {title = 'In ' .. minutes .. ' minutes…', fn = function() M.quickReminder(minutes) end})
      end
      if #sessions.reminders > 0 then
        table.insert(reminders, {title = '-'})
        for _, reminder in ipairs(sessions.reminders) do
          local id = reminder.id
          table.insert(reminders, {title = reminder.text .. ' · ' .. math.max(0, math.ceil(reminder.remainingSeconds / 60)) .. ' min', menu = {
            {title = 'Cancel Reminder', fn = function() sessionAction(function() return M.sessions.cancel(id) end) end},
          }})
        end
      end
      table.insert(items, {title = 'Quick Reminder', menu = reminders})
      table.insert(items, {title = '-'})
      if current.active or current.stopping then
        table.insert(items, {title = current.stopping and 'Stopping Holding Pattern…' or ('Awake · ' .. minutes .. ' min left'), disabled = true})
        table.insert(items, {title = current.display and 'System and display stay awake' or 'Display can sleep', disabled = true})
        table.insert(items, {title = 'Stop Keeping Awake', disabled = current.stopping, fn = function() M.hold.stop() end})
      else
        local durations = {}
        for _, value in ipairs({15, 30, 60, 120}) do
          local duration = value
          table.insert(durations, {title = duration .. ' minutes', fn = function()
            local result = M.hold.start(duration, false)
            if not result.ok then hs.alert.show(result.lastError) end
          end})
        end
        table.insert(durations, {title = '-'})
        table.insert(durations, {title = 'Mac and display · 30 minutes', fn = function()
          local result = M.hold.start(30, true)
          if not result.ok then hs.alert.show(result.lastError) end
        end})
        table.insert(items, {title = 'Keep Awake', menu = durations})
      end
      table.insert(items, {title = '-'})
      table.insert(items, {title = 'Ground Control…', fn = function() M.openUtility('settings') end})
      return items
    end)
  end
  local timerActive = sessions.focus.state == 'running'
  M.holdMenu:setTitle((status.active or timerActive) and '✈︎ ◷' or '✈︎')
  M.holdMenu:setTooltip(timerActive and 'Hangar — Turnaround timer active' or status.active and 'Hangar — Holding Pattern active' or 'Hangar')
end
M.hold.setOnChange(updateHoldMenu)
M.sessions.setOnChange(updateHoldMenu)
M.sessions.setOpenCallback(function() M.openUtility('settings', 'sessions') end)
local previousShutdown = hs.shutdownCallback
hs.shutdownCallback = function()
  M.hold.shutdown()
  M.sessions.shutdown()
  if previousShutdown then previousShutdown() end
end
M.palette = require("leanmac-palette")
function M.openUtility(kind, tab)
  if kind == 'shelf' and U.modules and U.modules.shelf == false then
    hs.alert.show('Apron is disabled in Hangar settings'); return
  end
  local bundle = kind == 'shelf' and 'HangarShelf.app' or 'HangarSettings.app'
  local program = kind == 'shelf' and hs.configdir .. '/bin/HangarShelf.app/Contents/MacOS/hangar-shelf' or '/usr/bin/open'
  local arguments = kind == 'shelf' and {'--wait', '--style', U.shelf_style or 'compact'} or {hs.configdir .. '/bin/' .. bundle}
  if kind == 'settings' and tab == 'sessions' then
    arguments = {hs.configdir .. '/bin/' .. bundle, '--args', '--tab', tab}
  end
  local task
  task = hs.task.new(program, function(code, out, err)
    M.tasks[task] = nil
    if code == 0 and kind == 'settings' and tab == 'sessions' then
      hs.distributednotifications.post('local.hangar.settings.navigate', nil, {tab = tab})
    end
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
