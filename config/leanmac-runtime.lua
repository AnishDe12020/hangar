-- Bounded, asynchronous commands shared by the health check and palette.
local R = {tasks = {}}
R.aerospace = hs.fs.attributes('/opt/homebrew/bin/aerospace') and '/opt/homebrew/bin/aerospace' or '/usr/local/bin/aerospace'
R.cli = os.getenv('HOME') .. '/.local/bin/leanmac'
function R.run(command, args, callback, seconds)
  local task, timer, done
  local function finish(code, out, err)
    if done then return end
    done = true
    if timer then timer:stop() end
    if task then R.tasks[task] = nil end
    if callback then callback(code, out or '', err or '') end
  end
  task = hs.task.new(command, finish, args)
  if not task then finish(127, '', 'Could not create task'); return end
  R.tasks[task] = true
  timer = hs.timer.doAfter(seconds or 5, function()
    finish(124, '', 'Command timed out')
    task:terminate()
  end)
  if not task:start() then finish(127, '', 'Could not start ' .. command) end
  return task
end
local previousShutdown = hs.shutdownCallback
hs.shutdownCallback = function()
  for task in pairs(R.tasks) do task:terminate() end
  if previousShutdown then previousShutdown() end
end
return R
