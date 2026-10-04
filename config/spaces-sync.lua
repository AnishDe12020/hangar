-- AeroSpace hides inactive workspaces off-screen. Extra macOS Spaces desync that.
-- Gathering is an explicit, confirmed action; loading this module is read-only.
local M = {}
local cli = hs.fs.attributes('/opt/homebrew/bin/aerospace') and '/opt/homebrew/bin/aerospace' or '/usr/local/bin/aerospace'
local collapsing = false
M.tasks = {}
local function aero(args)
  local task
  task = hs.task.new(cli, function(code, out, err)
    M.tasks[task] = nil
    if code ~= 0 then hs.printf('LeanMac spaces: %s', err or out) end
  end, args)
  if task then M.tasks[task] = true; task:start() end
end
local function userSpaces(ids)
  local list = {}
  for _, id in ipairs(ids or {}) do
    if hs.spaces.spaceType(id) == 'user' then table.insert(list, id) end
  end
  return list
end
local function moveWindows(fromSpace, toSpace)
  local ok, windows = pcall(hs.spaces.windowsForSpace, fromSpace)
  if not ok or type(windows) ~= 'table' then return end
  for _, win in ipairs(windows) do
    pcall(hs.spaces.moveWindowToSpace, win, toSpace)
  end
end
local function gatherWindows(ids, keep)
  for _, id in ipairs(ids) do
    if id ~= keep then moveWindows(id, keep) end
  end
end
function M.collapse()
  if collapsing or not hs.spaces then return end
  collapsing = true
  local changed = false
  local present = {}
  for _, screen in ipairs(hs.screen.allScreens()) do
    present[screen:getUUID()] = screen
  end
  local all = hs.spaces.allSpaces() or {}
  for uuid, ids in pairs(all) do
    local users = userSpaces(ids)
    local screen = present[uuid]
    if screen then
      if #users > 1 then
        local keep = hs.spaces.activeSpaceOnScreen(screen) or users[1]
        gatherWindows(users, keep)
        changed = true
      end
    else
      -- Spaces left behind by a disconnected display.
      if #users > 0 then
        local fallbackScreen = hs.screen.mainScreen()
        local fallback = hs.spaces.activeSpaceOnScreen(fallbackScreen)
        if fallback then gatherWindows(users, fallback) end
        changed = true
      end
    end
  end
  if changed then aero({'reload-config', '--no-gui'}) end
  collapsing = false
  return changed
end
local function extraCount()
  local n, present = 0, {}
  for _, screen in ipairs(hs.screen.allScreens()) do present[screen:getUUID()] = true end
  for uuid, ids in pairs(hs.spaces.allSpaces() or {}) do
    local users = userSpaces(ids)
    if present[uuid] then n = n + math.max(#users - 1, 0) else n = n + #users end
  end
  return n
end
function M.report()
  local n = extraCount()
  if n > 0 then
    hs.alert.show(n .. ' extra macOS Desktop(s). ⌃⌥⌘S gathers windows onto this one; delete extras in Mission Control')
  end
  return n
end
function M.collapseNow()
  local n = extraCount()
  if n == 0 then hs.alert.show('Already one macOS Desktop per display'); return end
  if hs.dialog.blockAlert('Gather windows?', 'Move windows from extra native Desktops onto the current Desktop on each display? This does not delete Desktops.', 'Gather', 'Cancel') ~= 'Gather' then return end
  if M.collapse() then hs.alert.show('Moved windows onto this Desktop. Delete leftover Desktops in Mission Control') else hs.alert.show('Could not gather windows') end
end
-- Do not watch Space changes: Mission Control APIs can hitch WindowServer.
M.hotkey = hs.hotkey.bind({'ctrl', 'alt', 'cmd'}, 's', M.collapseNow)
return M
