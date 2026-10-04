-- Local focus sessions and reminders. Completion is saved before notification.
local M = {}
local function copy(value)
  if type(value) ~= 'table' then return value end
  local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end
local function integer(value, low, high)
  return type(value) == 'number' and value == math.floor(value) and value >= low and value <= high
end
local function textOK(value)
  return type(value) == 'string' and #value <= 1120 and not value:find('[%z\1-\31\127]')
    and value:match('%S') and utf8.len(value) and utf8.len(value) <= 280
end
local function idle()
  return {state = 'idle', phase = 'focus', nextPhase = 'focus', endsAt = 0, remainingSeconds = 0,
          completedFocus = 0, focusMinutes = 25, breakMinutes = 5, longBreakMinutes = 15}
end
local function duration(focus, phase)
  return 60 * focus[phase == 'focus' and 'focusMinutes' or phase == 'break' and 'breakMinutes' or 'longBreakMinutes']
end
local function valid(data)
  if type(data) ~= 'table' or data.schema ~= 1 or not integer(data.nextID, 1, 9007199254740990)
    or type(data.reminders) ~= 'table' or #data.reminders > 20 or type(data.focus) ~= 'table' then return false end
  local f = data.focus
  if not ({idle = true, running = true, paused = true, awaiting_next = true})[f.state]
    or not ({focus = true, ['break'] = true, long_break = true})[f.phase]
    or not ({focus = true, ['break'] = true, long_break = true})[f.nextPhase]
    or not integer(f.focusMinutes, 1, 180) or not integer(f.breakMinutes, 1, 60)
    or not integer(f.longBreakMinutes, 1, 120) or not integer(f.completedFocus, 0, 1000000)
    or type(f.endsAt) ~= 'number' or f.endsAt < 0 or f.endsAt >= math.huge or f.endsAt ~= f.endsAt
    or not integer(f.remainingSeconds, 0, 10800) then return false end
  local ids, count = {}, 0
  for key, reminder in pairs(data.reminders) do
    count = count + 1
    if not integer(key, 1, #data.reminders) or type(reminder) ~= 'table'
      or not integer(reminder.id, 1, data.nextID - 1) or ids[reminder.id] or not textOK(reminder.text)
      or type(reminder.endsAt) ~= 'number' or reminder.endsAt < 0 or reminder.endsAt >= math.huge
      or reminder.endsAt ~= reminder.endsAt then return false end
    ids[reminder.id] = true
  end
  return count == #data.reminders
end

local function nativeDependencies()
  local base = os.getenv('HOME') .. '/Library/Application Support/LeanMac'
  local directory, path = base .. '/Sessions', base .. '/Sessions/state.json'
  local notificationTag, openCurrent = 'hangar.sessions.open', nil
  -- A stable tag reconnects notifications delivered before a normal reload.
  hs.notify.register(notificationTag, function(notification)
    local activation = notification:activationType()
    if openCurrent and (activation == hs.notify.activationTypes.ContentsClicked
      or activation == hs.notify.activationTypes.ActionButtonClicked) then pcall(openCurrent) end
  end)
  local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
  local function privateDirectory()
    for _, target in ipairs({base, directory}) do
      local kind = hs.fs.symlinkAttributes(target, 'mode')
      if kind and kind ~= 'directory' then return nil end
      if not kind and not hs.fs.mkdir(target) then return nil end
    end
    if hs.fs.attributes(directory, 'permissions') ~= 'rwx------' then
      local _, ok = hs.execute('/bin/chmod 700 ' .. quote(directory), false)
      if not ok or hs.fs.attributes(directory, 'permissions') ~= 'rwx------' then return nil end
    end
    return true
  end
  return {
    now = hs.timer.secondsSinceEpoch,
    read = function()
      if hs.fs.symlinkAttributes(directory, 'mode') and not privateDirectory() then
        return nil, 'Cannot access private session storage.'
      end
      local kind = hs.fs.symlinkAttributes(path, 'mode')
      if not kind then return nil end
      if kind ~= 'file' or not privateDirectory() then return nil, 'Private session storage is not a regular local file.' end
      local file = io.open(path, 'rb')
      if not file then return nil, 'Cannot read private session storage.' end
      local content = file:read(131073); file:close()
      if not content or #content > 131072 then return nil, 'Private session storage is too large.' end
      local ok, result = pcall(hs.json.decode, content)
      if not ok or not result then return nil, 'Private session storage contains invalid JSON.' end
      return result
    end,
    write = function(data)
      if not privateDirectory() then return nil, 'Cannot create private session storage.' end
      local kind = hs.fs.symlinkAttributes(path, 'mode')
      if kind and kind ~= 'file' then return nil, 'Session storage must be a regular file, not a link.' end
      local temp = directory .. '/state-' .. hs.host.uuid() .. '.tmp'
      local file = io.open(temp, 'wb')
      if not file then return nil, 'Cannot prepare session save.' end
      local _, secured = hs.execute('/bin/chmod 600 ' .. quote(temp), false)
      if not secured then file:close(); os.remove(temp); return nil, 'Cannot protect private session storage.' end
      local encoded, content = pcall(hs.json.encode, data)
      local wrote = encoded and content and file:write(content)
      local closed = file:close()
      if not wrote or not closed then os.remove(temp); return nil, 'Could not finish session save.' end
      local renamed = os.rename(temp, path)
      if not renamed then os.remove(temp); return nil, 'Could not replace session storage.' end
      return true
    end,
    after = hs.timer.doAfter,
    watch = function(callback)
      local events = hs.caffeinate.watcher
      return events.new(function(event)
        if event == events.systemDidWake or event == events.screensDidUnlock then callback() end
      end):start()
    end,
    setOpenCallback = function(callback) openCurrent = callback end,
    notify = function(title, text)
      return hs.notify.new(notificationTag, {title = title, informativeText = text,
        alwaysPresent = false, withdrawAfter = 0}):send()
    end,
  }
end

function M.new(deps)
  deps = deps or nativeDependencies()
  local S, data = {}, {schema = 1, nextID = 1, focus = idle(), reminders = {}}
  local lastError, loadError, timer, watcher, onChange, openCallback, stopped, reconciling = '', nil, nil, nil, nil, nil, false, false
  local ok, saved, readError = pcall(deps.read)
  if not ok or readError or (saved and not valid(saved)) then
    loadError = 'Session storage could not be loaded. Preserve and repair Sessions/state.json, then reload Hangar.'
    lastError = loadError
  elseif saved then data = saved end

  local function snapshot()
    local focus, reminders = copy(data.focus), copy(data.reminders)
    if focus.state == 'running' then
      focus.remainingSeconds = math.min(duration(focus, focus.phase), math.max(0, math.ceil(focus.endsAt - deps.now())))
    end
    for _, reminder in ipairs(reminders) do reminder.remainingSeconds = math.max(0, math.ceil(reminder.endsAt - deps.now())) end
    table.sort(reminders, function(a, b) return a.endsAt == b.endsAt and a.id < b.id or a.endsAt < b.endsAt end)
    return {focus = focus, reminders = reminders, lastError = lastError}
  end
  local function changed() if onChange then pcall(onChange, snapshot()) end end
  local function receipt(success, extra)
    local result = {ok = success, status = snapshot()}
    if not success then result.error = lastError end
    for key, value in pairs(extra or {}) do result[key] = value end
    return result
  end
  local function fail(message) lastError = message; changed(); return receipt(false) end
  local function commit(candidate)
    if stopped or loadError then lastError = loadError or 'Sessions has shut down. Reload Hangar.'; return false end
    local wrote, result = pcall(deps.write, candidate)
    if not wrote or not result then lastError = 'Could not save sessions. Check private storage permissions and free space, then try again.'; return false end
    data, lastError = candidate, ''; return true
  end
  local reconcile
  local function schedule()
    if timer then timer:stop(); timer = nil end
    if stopped or loadError then return end
    local deadline = data.focus.state == 'running' and data.focus.endsAt or math.huge
    for _, reminder in ipairs(data.reminders) do deadline = math.min(deadline, reminder.endsAt) end
    if deadline < math.huge then
      timer = deps.after(math.max(0.01, deadline - deps.now()), function() timer = nil; reconcile() end)
    end
  end
  reconcile = function()
    if stopped or loadError or reconciling then return end
    reconciling = true
    local candidate, notices, now = copy(data), {}, deps.now()
    local focus = candidate.focus
    if focus.state == 'running' and focus.endsAt <= now then
      if focus.phase == 'focus' then
        focus.completedFocus = focus.completedFocus + 1
        focus.nextPhase = focus.completedFocus % 4 == 0 and 'long_break' or 'break'
        notices[#notices + 1] = {'Hangar · Focus finished', 'Time for a ' .. (focus.nextPhase == 'long_break' and 'long break' or 'break') .. '. Open Sessions when you are ready.'}
      else
        focus.nextPhase = 'focus'
        notices[#notices + 1] = {'Hangar · Break finished', 'Ready for another focus session? Open Sessions to start.'}
      end
      focus.state, focus.endsAt, focus.remainingSeconds = 'awaiting_next', 0, 0
    end
    candidate.reminders = {}
    for _, reminder in ipairs(data.reminders) do
      if reminder.endsAt <= now then notices[#notices + 1] = {'Hangar · Reminder', reminder.text}
      else candidate.reminders[#candidate.reminders + 1] = reminder end
    end
    if #notices > 0 then
      if not commit(candidate) then
        -- No retry loop on disk failure; the next wake or user action retries.
        if timer then timer:stop(); timer = nil end
        changed(); reconciling = false; return
      end
      for _, notice in ipairs(notices) do
        local delivered, notification = pcall(deps.notify, notice[1], notice[2], function() if openCallback then pcall(openCallback) end end)
        if not delivered or not notification then lastError = 'Completion was saved, but its macOS notification could not be sent.' end
      end
      changed()
    end
    schedule(); reconciling = false
  end
  local function update(candidate, extra)
    if not commit(candidate) then changed(); return receipt(false) end
    schedule(); changed(); return receipt(true, extra)
  end
  function S.status() reconcile(); return snapshot() end
  function S.list() reconcile(); return snapshot().reminders end
  function S.setOnChange(callback)
    if callback ~= nil and type(callback) ~= 'function' then return false end
    onChange = callback; changed(); return true
  end
  function S.setOpenCallback(callback)
    if callback ~= nil and type(callback) ~= 'function' then return false end
    openCallback = callback
    if deps.setOpenCallback then deps.setOpenCallback(callback) end
    return true
  end
  function S.startFocus(options)
    options = options or {}
    if type(options) ~= 'table' then return fail('Focus settings must be an object.') end
    local focus = idle()
    for key, value in pairs(options) do
      local maximum = ({focusMinutes = 180, breakMinutes = 60, longBreakMinutes = 120})[key]
      if not maximum or not integer(value, 1, maximum) then return fail('Choose whole minutes: focus 1–180, break 1–60, long break 1–120.') end
      focus[key] = value
    end
    reconcile(); local candidate = copy(data)
    focus.state, focus.endsAt = 'running', deps.now() + duration(focus, 'focus')
    candidate.focus = focus; return update(candidate)
  end
  function S.pauseFocus()
    reconcile(); local candidate = copy(data); local focus = candidate.focus
    if focus.state ~= 'running' then return fail('There is no running focus or break session to pause.') end
    focus.remainingSeconds = math.min(duration(focus, focus.phase), math.max(1, math.ceil(focus.endsAt - deps.now())))
    focus.endsAt, focus.state = 0, 'paused'
    return update(candidate)
  end
  function S.resumeFocus()
    reconcile(); local candidate = copy(data); local focus = candidate.focus
    if focus.state ~= 'paused' then return fail('There is no paused session to resume.') end
    focus.endsAt, focus.remainingSeconds, focus.state = deps.now() + focus.remainingSeconds, 0, 'running'
    return update(candidate)
  end
  function S.nextFocus()
    reconcile(); local candidate = copy(data); local focus = candidate.focus
    if focus.state ~= 'awaiting_next' then return fail('Finish the current session before starting the next phase.') end
    focus.phase, focus.state = focus.nextPhase, 'running'
    focus.endsAt = deps.now() + duration(focus, focus.phase)
    return update(candidate)
  end
  function S.cancelFocus()
    local candidate = copy(data); candidate.focus = idle(); return update(candidate)
  end
  function S.add(text, minutes)
    if not textOK(text) then return fail('Use a single reminder line of 1–280 characters.') end
    if not integer(minutes, 1, 10080) then return fail('Choose a whole number of minutes from 1 to 10080 (7 days).') end
    reconcile()
    if #data.reminders >= 20 then return fail('There are already 20 reminders. Cancel one before adding another.') end
    local candidate = copy(data); local id = candidate.nextID
    candidate.nextID = id + 1
    candidate.reminders[#candidate.reminders + 1] = {id = id, text = text:match('^%s*(.-)%s*$'), endsAt = deps.now() + minutes * 60}
    return update(candidate, {id = id})
  end
  function S.cancel(id)
    if not integer(id, 1, 9007199254740990) then return fail('Choose an existing reminder ID.') end
    local candidate, found = copy(data), false
    for index, reminder in ipairs(candidate.reminders) do
      if reminder.id == id then table.remove(candidate.reminders, index); found = true; break end
    end
    if not found then return fail('That reminder no longer exists.') end
    return update(candidate)
  end
  function S.shutdown()
    stopped = true
    if timer then timer:stop(); timer = nil end
    if watcher then watcher:stop(); watcher = nil end
    return receipt(true)
  end
  watcher = deps.watch(reconcile)
  reconcile()
  return S
end

return M
