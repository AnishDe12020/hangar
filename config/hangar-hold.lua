-- Timed, owned sleep assertions. No global power settings or polling timers.
local H = {}
local owned, current, onChange = {}, nil, nil
local lastError = ''

function H.status()
  local state = {active = false, endsAt = 0, display = false, remainingSeconds = 0,
                 stopping = false, lastError = lastError}
  for session in pairs(owned) do
    if session.task:isRunning() then
      state.active = true
      state.endsAt = math.max(state.endsAt, session.endsAt)
      state.display = state.display or session.display
      state.stopping = state.stopping or session.stopping == true
    end
  end
  state.remainingSeconds = math.max(0, math.ceil(state.endsAt - hs.timer.secondsSinceEpoch()))
  return state
end

local function changed()
  if onChange then pcall(onChange, H.status()) end
end

function H.setOnChange(callback)
  if callback ~= nil and type(callback) ~= 'function' then return false end
  onChange = callback
  changed()
  return true
end

local function receipt(ok, action)
  local result = H.status()
  result.ok, result.action = ok, action
  if not ok then result.error = lastError end
  return result
end

local function failure(message)
  lastError = message
  changed()
  return receipt(false, 'failed')
end

local function terminate(session)
  if not session.task:isRunning() then return true end
  local ok, err = pcall(function() session.task:terminate() end)
  if not ok then
    lastError = 'Could not stop Holding Pattern. Try Stop again or quit Hammerspoon: ' .. tostring(err)
    return false
  end
  session.stopping = true
  return true
end

function H.start(minutes, display)
  if type(minutes) ~= 'number' or minutes ~= math.floor(minutes) or minutes < 1 or minutes > 1440 then
    return failure('Choose a whole number of minutes from 1 to 1440.')
  end
  if display ~= nil and type(display) ~= 'boolean' then
    return failure('Keep display awake must be true or false.')
  end
  local pid = hs.processInfo and hs.processInfo.processID
  if type(pid) ~= 'number' or pid < 1 or pid ~= math.floor(pid) then
    return failure('Hammerspoon process ID is unavailable. Reload Hangar before starting Holding Pattern.')
  end
  local args = {'-i'}
  if display then args[#args + 1] = '-d' end
  for _, value in ipairs({'-t', string.format('%d', minutes * 60), '-w', string.format('%d', pid)}) do args[#args + 1] = value end
  local session = {endsAt = hs.timer.secondsSinceEpoch() + minutes * 60, display = display == true}
  local ok, task = pcall(hs.task.new, '/usr/bin/caffeinate', function(code, _, stderr)
    owned[session] = nil
    if current == session then
      current = nil
      if code ~= 0 and not session.stopping then
        local detail = tostring(stderr or ''):gsub('[\r\n]+', ' '):sub(1, 500)
        lastError = 'Holding Pattern exited (' .. tostring(code) .. '). Try starting it again.'
          .. (detail ~= '' and ' ' .. detail or '')
      end
    end
    changed()
  end, args)
  if not ok or not task then
    return failure('Could not create /usr/bin/caffeinate. Check the Hammerspoon Console and try again.')
  end
  session.task = task
  local started, result = pcall(function() return task:start() end)
  if not started or not result then
    return failure('Could not start /usr/bin/caffeinate. Check the Hammerspoon Console and try again.')
  end
  -- Start the successor before retiring the previous task: launch failure keeps
  -- the existing hold intact. Keep retiring handles until their exit callbacks.
  owned[session] = true
  local clean = true
  for previous in pairs(owned) do
    if previous ~= session and not terminate(previous) then clean = false end
  end
  current = session
  if clean then lastError = '' end
  changed()
  return receipt(clean, clean and 'started' or 'failed')
end

function H.stop()
  lastError = ''
  local ok = true
  for session in pairs(owned) do
    if not terminate(session) then ok = false end
  end
  changed()
  return receipt(ok, ok and (H.status().active and 'stopping' or 'stopped') or 'failed')
end

function H.shutdown()
  return H.stop()
end

return H
