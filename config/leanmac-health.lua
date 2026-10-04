local R = require('leanmac-runtime')
local H = {version = 1, locked = false, runs = 0}
local function enabled(key) return key ~= nil and key.enabled == true end

-- Read-only snapshot, also used by the CLI when an earlier init failed.
function H.snapshot()
  local m = rawget(_G, 'leanmac') or {}
  local p, s, mx, palette = m.picker or {}, m.snap or {}, m.mx or {}, m.palette or {}
  local groups = m.groups or {}
  local snapshot = {
    version = m.version, configdir = hs.configdir, accessibility = hs.accessibilityState(),
    secureInput = hs.eventtap.isSecureInputEnabled(), loaded = m.version ~= nil,
    pickerSubscriber = p.subscriber ~= nil and p.subscriber:isRunning(),
    pickerPanel = p.panel ~= nil and p.panel.ready and p.panel.task ~= nil and p.panel.task:isRunning(),
    pickerWindows = #(p.cache or {}), pickerForward = enabled(p.forward),
    pickerBackward = enabled(p.backward), pickerSearch = enabled(p.search),
    snapKeys = enabled(s.left) and enabled(s.right) and enabled(s.up) and enabled(s.down),
    snapMouse = s.mouse ~= nil and s.mouse:isEnabled(), mxPicker = enabled(mx.picker),
    groupKeys = enabled(groups.pairKey) and enabled(groups.separateKey) and enabled(groups.menuKey),
    overviewKey = m.overview ~= nil and enabled(m.overview.hotkey),
    paletteKey = enabled(palette.hotkey), paletteCommands = #(palette.choices or {}),
    healthWatcher = m.health ~= nil and H.sessionWatcher ~= nil,
    nativeRouterLoaded = package.loaded['hotkey-router'] ~= nil,
    screens = {}, extraDesktops = 0, lastHealthReason = H.lastReason,
  }
  local ok, err = pcall(function()
    local present = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
      local uuid = screen:getUUID()
      present[uuid] = true
      table.insert(snapshot.screens, {name = screen:name(), uuid = uuid})
    end
    for uuid, ids in pairs(hs.spaces.allSpaces() or {}) do
      local count = 0
      for _, id in ipairs(ids) do if hs.spaces.spaceType(id) == 'user' then count = count + 1 end end
      snapshot.extraDesktops = snapshot.extraDesktops + (present[uuid] and math.max(0, count - 1) or count)
    end
  end)
  if not ok then snapshot.spacesError = tostring(err); snapshot.extraDesktops = nil end
  return snapshot
end

function H.check(reason, manual, followup)
  if H.locked then return end
  if H.running then H.pending = {reason, manual}; return end
  H.running, H.lastReason, H.runs = true, reason or 'manual', H.runs + 1
  R.run(R.cli, {'doctor', '--json'}, function(_, out, err)
    H.running = false
    local ok, result = pcall(hs.json.decode, out)
    if not ok or type(result) ~= 'table' or not result.checks then
      H.lastError = err ~= '' and err or 'Doctor returned no report'
      if not H.locked then hs.alert.show('LeanMac health check unavailable. Run leanmac doctor in Terminal.') end
      return
    end
    H.lastReport = result
    local warnings = {}
    for _, check in ipairs(result.checks) do
      if check.status ~= 'ok' then table.insert(warnings, check.message) end
    end
    local signature = table.concat(warnings, '\n')
    if H.locked then return end
    -- Password fields can legitimately keep Secure Input active briefly after unlock.
    if result.secureInput == true and not manual and not followup then
      H.retry = hs.timer.doAfter(5, function() H.check(reason, false, true) end)
    elseif #warnings > 0 then
      if manual or signature ~= H.lastWarning or hs.timer.secondsSinceEpoch() - (H.warnedAt or 0) > 300 then
        hs.alert.show('LeanMac · ' .. table.concat(warnings, '\n') .. '\n⌃⌥⌘/ → Diagnose for details', 8)
        H.lastWarning, H.warnedAt = signature, hs.timer.secondsSinceEpoch()
      end
    else
      H.lastWarning = nil
      if manual then hs.alert.show('LeanMac checks passed') end
    end
    if H.pending then
      local pending = H.pending; H.pending = nil
      H.schedule(pending[1], pending[2])
    end
  end, 18)
end

function H.schedule(reason, manual)
  if H.timer then H.timer:stop() end
  if H.retry then H.retry:stop(); H.retry = nil end
  H.timer = hs.timer.doAfter(3, function()
    H.timer = nil
    H.check(reason, manual)
  end)
end

function H.onSessionEvent(event)
  local c = hs.caffeinate.watcher
  if event == c.screensDidLock or event == c.sessionDidResignActive or event == c.systemWillSleep then
    H.locked = true
    if H.timer then H.timer:stop(); H.timer = nil end
    if H.retry then H.retry:stop(); H.retry = nil end
  elseif event == c.screensDidUnlock or event == c.sessionDidBecomeActive then
    H.locked = false
    H.schedule('unlock')
  elseif event == c.systemDidWake or event == c.screensDidWake then
    if not H.locked then H.schedule('wake') end
  end
end

H.sessionWatcher = hs.caffeinate.watcher.new(H.onSessionEvent):start()
H.screenWatcher = hs.screen.watcher.new(function()
  -- Retain the existing display-change reload, with one debounced health check.
  if H.displayTimer then H.displayTimer:stop() end
  H.displayTimer = hs.timer.doAfter(2, function()
    if H.locked then return end
    R.run(R.aerospace, {'reload-config', '--no-gui'}, function() H.schedule('display-change') end)
  end)
end):start()
H.schedule('startup')
return H
