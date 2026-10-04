-- Explicit split pairs. AeroSpace owns the tree; there is no shadow layout or polling.
local R = require('leanmac-runtime')
local links = require('window-links')
local G = {busy = false}
local helper = hs.configdir .. '/bin/leanmac-window-focus'
local format = '%{window-id} %{workspace} %{window-parent-container-layout} %{workspace-root-container-layout} %{app-pid}'
local function alert(message) hs.alert.show('Layouts · ' .. message) end
local function notifyBoard()
  if leanmac and leanmac.overview and leanmac.overview.scheduleRefresh then leanmac.overview.scheduleRefresh() end
end
local function fail(message)
  G.layoutEpoch = (G.layoutEpoch or 0) + 1
  G.busy = false; G.lastResult = false; G.lastError = message; alert(message); notifyBoard()
  leanmac.picker.refresh()
end
local function succeed(message)
  G.layoutEpoch = (G.layoutEpoch or 0) + 1
  G.busy = false; G.lastResult = true; G.lastError = nil; alert(message)
  leanmac.picker.refresh(); notifyBoard()
end
local function run(args, done)
  R.run(R.aerospace, args, function(code, out, err)
    if code ~= 0 then fail('Command failed; layout may be partly changed'); hs.printf('LeanMac layouts: %s', err); return end
    if done then done(out) end
  end)
end
local function read(workspace, done, failed)
  R.run(R.aerospace, {'list-windows', '--workspace', workspace, '--format', format, '--json'}, function(code, out)
    local ok, rows = pcall(hs.json.decode, out)
    if code ~= 0 or not ok or type(rows) ~= 'table' then
      if failed then failed() else fail('Could not read this space') end
      return
    end
    local byID = {}; for _, row in ipairs(rows) do byID[row['window-id']] = row end
    done(byID)
  end)
end
local workspaceFormat = '%{workspace} %{monitor-id} %{monitor-name} %{workspace-is-visible} %{workspace-is-focused}'
local function readWorkspaces(done)
  R.run(R.aerospace, {'list-workspaces', '--all', '--format', workspaceFormat, '--json'}, function(code, out)
    local ok, rows = pcall(hs.json.decode, out)
    done(code == 0 and ok and type(rows) == 'table' and rows or nil)
  end)
end
local function monitorKey(row)
  return tostring(row['monitor-id']) .. ':' .. tostring(row['monitor-name'])
end
function G.origin()
  local win = hs.window.focusedWindow()
  local cached = win and leanmac.picker.byID[win:id()]
  if not win or not cached or not win:isStandard() or win:isFullScreen() or win:isMinimized() then
    alert('Focus a normal window first'); return nil
  end
  return {id = win:id(), pid = win:pid(), workspace = cached.workspace, monitor = cached.monitor, restores = {}}
end
local function valid(origin)
  local win = origin and hs.window.get(origin.id)
  return win and win:pid() == origin.pid and win:isStandard() and not win:isFullScreen() and not win:isMinimized()
end
local function exactFocus(origin, done)
  if not valid(origin) then done(false, 'Window closed or unavailable'); return end
  -- Snapshot other-monitor fronts now, not before a potentially long chooser interaction.
  local args, seen = {tostring(origin.pid), tostring(origin.id)}, {}
  for _, win in ipairs(hs.window.orderedWindows()) do
    local cached = leanmac.picker.byID[win:id()]
    if cached and cached.visible and cached.monitor ~= origin.monitor and not seen[cached.monitor] then
      local screen = win:screen()
      local space = screen and hs.spaces.activeSpaceOnScreen(screen)
      if space then
        table.insert(args, tostring(space)); table.insert(args, tostring(win:pid()))
        seen[cached.monitor] = true
      end
    end
  end
  local function activateExact()
  R.run(helper, args, function(code)
    if code ~= 0 or not valid(origin) then done(false, 'Could not restore the exact window'); return end
    hs.window.get(origin.id):raise()
    hs.timer.doAfter(0.12, function()
      local focused = hs.window.focusedWindow()
      if not focused or focused:id() ~= origin.id then done(false, 'Focus changed; cancelled'); return end
      -- Native focus and AeroSpace's workspace selection are separate state.
      R.run(R.aerospace, {'list-windows', '--focused', '--format', format, '--json'}, function(exitCode, out)
        local ok, rows = pcall(hs.json.decode, out)
        local row = ok and type(rows) == 'table' and rows[1]
        local current = hs.window.focusedWindow()
        done(exitCode == 0 and row and row['window-id'] == origin.id
          and row['app-pid'] == origin.pid and row.workspace == origin.workspace
          and current and current:id() == origin.id or false, 'Workspace focus changed')
      end)
    end)
  end)
  end
  read(origin.workspace, function(rows)
    if not rows[origin.id] or rows[origin.id]['app-pid'] ~= origin.pid or not valid(origin) then
      done(false, 'Window left this space'); return
    end
    R.run(R.aerospace, {'focus', '--window-id', tostring(origin.id)}, function(code)
      if code ~= 0 then done(false, 'Could not select the pair workspace'); return end
      activateExact()
    end)
  end, function() done(false, 'Could not verify the focus destination') end)
end
local function focusOrigin(origin, done)
  exactFocus(origin, function(ok, message)
    if not ok then fail(message); return end
    done()
  end)
end
function G.validatePair(origin, partner, rows)
  if not origin or not partner or origin.id == partner.id then return false end
  local a, b = rows[origin.id], rows[partner.id]
  return a ~= nil and b ~= nil and a.workspace == origin.workspace and b.workspace == origin.workspace
    and a['app-pid'] == origin.pid and b['app-pid'] == partner.pid
end
-- A standalone view lives directly under the vertical workspace accordion.
-- A pair occupying the whole space becomes the root container itself after
-- native normalization; h_accordion there is still a linked pair, not standalone.
local function standalone(row)
  return row['window-parent-container-layout'] == 'floating'
    or (row['window-parent-container-layout'] == 'v_accordion'
      and row['workspace-root-container-layout'] == 'v_accordion')
end
local function samePair(pair, a, b)
  return type(pair) == 'table' and type(pair.a) == 'table' and type(pair.b) == 'table'
    and pair.a.id == a.id and pair.a.pid == a.pid and pair.b.id == b.id and pair.b.pid == b.pid
end
-- Menus carry the pair they displayed; a stale menu must not dissolve or swap
-- a pair that was re-formed, re-ordered or dissolved since it opened.
local function pairMatches(expected, actual)
  if expected == nil then return true end
  return type(expected) == 'table' and type(expected.a) == 'table' and type(expected.b) == 'table'
    and samePair(actual, expected.a, expected.b)
end
local function queryAll(done)
  R.run(R.aerospace, {'list-windows', '--all', '--format', format, '--json'}, function(code, out)
    local ok, rows = pcall(hs.json.decode, out)
    if code ~= 0 or not ok or type(rows) ~= 'table' then done(nil); return end
    local byID = {}; for _, row in ipairs(rows) do byID[row['window-id']] = row end
    done(rows, byID)
  end)
end
local function execute(args, done)
  R.run(R.aerospace, args, function(code, out, err) done(code == 0, out, err) end)
end
-- An empty scratch remains alive while any monitor displays it. Restore only
-- that exact scratch, never a real workspace the user selected during the job.
local function restoreScratchView(ctx, done)
  queryAll(function(windows)
    if not windows then done(false); return end
    for _, window in ipairs(windows) do
      if window.workspace == ctx.scratch then done(false); return end
    end
    readWorkspaces(function(spaces)
      if not spaces then done(false); return end
      local focused, target
      local byName = {}
      for _, row in ipairs(spaces) do
        byName[row.workspace] = row
        if row['workspace-is-focused'] then focused = row.workspace end
        if row.workspace == ctx.scratch and row['workspace-is-visible'] then target = row end
      end
      if not target then done(true); return end
      local previous = ctx.visible and ctx.visible[monitorKey(target)]
      local destination = previous and byName[previous]
      if not destination or monitorKey(destination) ~= monitorKey(target) then done(false); return end
      if focused == ctx.scratch then
        local original = ctx.focused and byName[ctx.focused]
        focused = original and (original['workspace-is-visible'] or ctx.focused == previous) and ctx.focused or nil
      end
      execute({'workspace', previous}, function(ok)
        if not ok then done(false); return end
        -- Switching another monitor also changes global focus. Put it back if
        -- it was on a real workspace, rather than on the scratch being removed.
        local function verified()
          readWorkspaces(function(after)
            if not after then done(false); return end
            for _, row in ipairs(after) do
              if row.workspace == ctx.scratch then done(false); return end
            end
            done(true)
          end)
        end
        if focused and focused ~= ctx.scratch and focused ~= previous and byName[focused] then
          execute({'workspace', focused}, function(restored)
            if restored then verified() else done(false) end
          end)
        else verified() end
      end)
    end)
  end)
end
local scratchSerial = 0
local function scratchName()
  scratchSerial = scratchSerial + 1
  local stamp = hs.timer.absoluteTime and hs.timer.absoluteTime() or (os.time() * 1000000 + scratchSerial)
  local name = 'LMPAIR' .. tostring(stamp):gsub('%D', '') .. tostring(scratchSerial)
  assert(name:match('^LMPAIR%d+$'), 'unsafe scratch workspace name')
  return name
end
local function selectedInScratch(ctx, rows)
  local selected, count = {}, 0
  for _, row in ipairs(rows) do
    if row.workspace == ctx.scratch then
      count = count + 1
      for _, item in ipairs(ctx.selected) do
        if row['window-id'] == item.id and row['app-pid'] == item.pid then selected[item.id] = true end
      end
    end
  end
  return selected, count
end
local function recover(ctx, done)
  local attempts = 0
  local function inspect()
    attempts = attempts + 1
    queryAll(function(rows)
      if not rows then
        if attempts < 3 then inspect() else done(false) end
        return
      end
      local found = selectedInScratch(ctx, rows)
      local returning = {}
      for _, item in ipairs(ctx.selected) do if found[item.id] then returning[#returning + 1] = item end end
      if #returning == 0 then done(true); return end
      if attempts >= 3 then done(false); return end
      local index = 1
      local function moveNext()
        local item = returning[index]
        if not item then inspect(); return end
        -- Re-query immediately before each recovery mutation. A window ID can
        -- be recycled, or the user can move the surviving window while a prior
        -- recovery command is in flight.
        queryAll(function(_, current)
          local row = current and current[item.id]
          if not row or row['app-pid'] ~= item.pid or row.workspace ~= ctx.scratch then
            index = index + 1; moveNext(); return
          end
          execute({'move-node-to-workspace', '--window-id', tostring(item.id), ctx.workspace}, function()
            index = index + 1; moveNext()
          end)
        end)
      end
      moveNext()
    end)
  end
  inspect()
end
local function abort(ctx, message)
  if ctx.aborting then return end
  ctx.aborting = true
  recover(ctx, function(recovered)
    if recovered then
      if ctx.mutated then message = message .. '; no selected windows remain in the temporary space; the pair may be separated' end
    else
      message = message .. '; recovery incomplete in ' .. ctx.scratch
    end
    restoreScratchView(ctx, function(restored)
      G.lastWorkspaceCleanup = restored
      if not restored then message = message .. '; temporary workspace needs inspection' end
      fail(message)
    end)
  end)
end
local function probeScratch(ctx, attempts, done)
  queryAll(function(rows)
    if not rows then fail('Could not inspect spaces'); return end
    for _, row in ipairs(rows) do
      if row.workspace == ctx.scratch then
        if attempts >= 6 then fail('Could not reserve a temporary space'); return end
        ctx.scratch = scratchName(); probeScratch(ctx, attempts + 1, done); return
      end
    end
    readWorkspaces(function(spaces)
      if not spaces then fail('Could not record visible workspaces'); return end
      ctx.visible = {}
      for _, row in ipairs(spaces) do
        if row['workspace-is-visible'] then ctx.visible[monitorKey(row)] = row.workspace end
        if row['workspace-is-focused'] then ctx.focused = row.workspace end
      end
      G.lastScratch = ctx.scratch
      done()
    end)
  end)
end
local function requireLocation(ctx, item, workspace, done)
  queryAll(function(_, byID)
    local row = byID and byID[item.id]
    if not row or row['app-pid'] ~= item.pid or row.workspace ~= workspace or not valid(item) then
      abort(ctx, 'A selected window changed spaces; pairing stopped'); return
    end
    done(row)
  end)
end
local function commandAt(ctx, item, workspace, args, done)
  requireLocation(ctx, item, workspace, function()
    execute(args, function(ok, _, err)
      if not ok then
        hs.printf('LeanMac layouts: %s', err or '')
        abort(ctx, 'Command failed during layout recovery'); return
      end
      done()
    end)
  end)
end
local function moveLeaf(ctx, item, from, destination, done)
  requireLocation(ctx, item, from, function()
    ctx.mutated = true
    execute({'move-node-to-workspace', '--window-id', tostring(item.id), destination}, function(ok, _, err)
      if not ok then
        hs.printf('LeanMac layouts: %s', err or '')
        abort(ctx, 'Could not move a selected window'); return
      end
      requireLocation(ctx, item, destination, done)
    end)
  end)
end
local function prepareScratch(ctx, done)
  queryAll(function(rows, byID)
    if not rows then abort(ctx, 'Could not inspect the temporary space'); return end
    local found, count = selectedInScratch(ctx, rows)
    for _, item in ipairs(ctx.selected) do
      if not found[item.id] then abort(ctx, 'A selected window left the temporary space'); return end
    end
    if count ~= #ctx.selected then abort(ctx, 'The temporary space was not empty'); return end
    local index = 1
    local function verifyPrepared()
      queryAll(function(finalRows, finalByID)
        if not finalRows then abort(ctx, 'Could not verify the temporary space'); return end
        local finalFound, finalCount = selectedInScratch(ctx, finalRows)
        if finalCount ~= #ctx.selected then abort(ctx, 'The temporary space changed during preparation'); return end
        for _, item in ipairs(ctx.selected) do
          local row = finalByID[item.id]
          if not finalFound[item.id] or not row or row['app-pid'] ~= item.pid
            or row['window-parent-container-layout'] == 'floating' then
            abort(ctx, 'A selected window did not become tiled in the temporary space'); return
          end
        end
        done()
      end)
    end
    local function prepareNext()
      local item = ctx.selected[index]
      if not item then verifyPrepared(); return end
      commandAt(ctx, item, ctx.scratch, {'fullscreen', '--window-id', tostring(item.id), 'off'}, function()
        local row = byID[item.id]
        if row and row['window-parent-container-layout'] == 'floating' then
          commandAt(ctx, item, ctx.scratch, {'layout', '--window-id', tostring(item.id), 'tiling'}, function()
            index = index + 1; prepareNext()
          end)
        else
          index = index + 1; prepareNext()
        end
      end)
    end
    prepareNext()
  end)
end
local function normalizeRoot(ctx, item, done)
  requireLocation(ctx, item, ctx.workspace, function(row)
    local function setVertical()
      commandAt(ctx, item, ctx.workspace,
        {'layout', '--window-id', tostring(item.id), '--root', 'v_accordion'}, done)
    end
    if tostring(row['workspace-root-container-layout'] or ''):sub(1, 1) == 'h' then
      commandAt(ctx, item, ctx.workspace,
        {'move', '--window-id', tostring(item.id), '--boundaries', 'workspace', 'down'}, setVertical)
    else
      setVertical()
    end
  end)
end
local function scratchEmpty(ctx, done)
  queryAll(function(rows)
    if not rows then abort(ctx, 'Could not verify the temporary space'); return end
    for _, row in ipairs(rows) do
      if row.workspace == ctx.scratch then abort(ctx, 'The temporary space did not empty'); return end
    end
    done()
  end)
end
local function readyToJoin(ctx, origin, partner, expected, done)
  queryAll(function(_, byID)
    local a, b = byID and byID[origin.id], byID and byID[partner.id]
    if not a or not b or a['app-pid'] ~= origin.pid or b['app-pid'] ~= partner.pid
      or a.workspace ~= ctx.workspace or b.workspace ~= ctx.workspace
      or not valid(origin) or not valid(partner) then
      abort(ctx, 'A selected window changed before the final join'); return
    end
    if not pairMatches(expected, links.containing(origin.id)) then
      abort(ctx, 'The linked pair changed before the final join'); return
    end
    done()
  end)
end
function G.pair(origin, partner, note, expected, preserveLayout)
  if G.busy then alert('Still arranging the previous split'); return end
  G.busy = true
  G.layoutEpoch = (G.layoutEpoch or 0) + 1
  G.lastResult = nil
  G.lastError = nil
  read(origin.workspace, function(rows)
    if not G.validatePair(origin, partner, rows) or not valid(origin) or not valid(partner) then
      fail('Both windows must still be in the same space'); return
    end
    local pairLayout = preserveLayout and rows[origin.id]['window-parent-container-layout'] or 'h_tiles'
    if preserveLayout and (pairLayout ~= rows[partner.id]['window-parent-container-layout']
      or (pairLayout ~= 'h_tiles' and pairLayout ~= 'h_accordion')) then
      fail('The linked pair layout changed'); return
    end
    if not pairMatches(expected, links.containing(origin.id)) then fail('The linked pair changed'); return end
    local ctx = {workspace=origin.workspace, scratch=scratchName(), selected={origin, partner}, mutated=false}
    probeScratch(ctx, 0, function()
      moveLeaf(ctx, origin, ctx.workspace, ctx.scratch, function()
        moveLeaf(ctx, partner, ctx.workspace, ctx.scratch, function()
          prepareScratch(ctx, function()
            moveLeaf(ctx, origin, ctx.scratch, ctx.workspace, function()
              normalizeRoot(ctx, origin, function()
                moveLeaf(ctx, partner, ctx.scratch, ctx.workspace, function()
                  readyToJoin(ctx, origin, partner, expected, function()
                    commandAt(ctx, partner, ctx.workspace,
                      {'join-with', '--window-id', tostring(partner.id), 'up'}, function()
                    local function verify()
                      scratchEmpty(ctx, function()
                        read(ctx.workspace, function(after)
                          if not G.validatePair(origin, partner, after)
                            or after[origin.id]['window-parent-container-layout'] ~= pairLayout
                            or after[partner.id]['window-parent-container-layout'] ~= pairLayout then
                            abort(ctx, 'Pair layout changed; inspect this space'); return
                          end
                          if not pairMatches(expected, links.containing(origin.id)) then
                            abort(ctx, 'The linked pair changed before completion'); return
                          end
                          links.link(origin, partner)
                          local message = note or 'Split ready · ⌥F zoom · ⌥⇧P separate'
                          restoreScratchView(ctx, function(restored)
                            G.lastWorkspaceCleanup = restored
                            if not restored then fail('Pair ready, but temporary workspace cleanup failed'); return end
                            exactFocus(origin, function(focusedOK)
                              if focusedOK then succeed(message) else succeed(message .. ' · exact focus unavailable') end
                            end)
                          end)
                        end, function() abort(ctx, 'Could not verify the returned pair') end)
                      end)
                    end
                    if pairLayout == 'h_accordion' then
                      commandAt(ctx, origin, ctx.workspace,
                        {'layout', '--window-id', tostring(origin.id), 'h_accordion'}, verify)
                    else
                      verify()
                    end
                  end)
                  end)
                end)
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end
function G.separate(origin, expected)
  origin = origin or G.origin(); if not origin then return end
  if G.busy then alert('Still arranging the previous split'); return end
  G.busy = true
  G.layoutEpoch = (G.layoutEpoch or 0) + 1
  G.lastResult = nil
  G.lastError = nil
  read(origin.workspace, function(rows)
    local row = rows[origin.id]
    if not row or row['app-pid'] ~= origin.pid or row.workspace ~= origin.workspace then
      fail('Window unavailable'); return
    end
    if not pairMatches(expected, links.containing(origin.id)) then
      fail('The linked pair changed; refresh and try again'); return
    end
    local linked = links.containing(origin.id)
    if not linked and standalone(row) then
      links.unlink(origin.id); succeed('Already a standalone window'); return
    end
    if not valid(origin) then fail('Window closed or unavailable'); return end
    local ctx = {workspace=origin.workspace, scratch=scratchName(), selected={origin}, mutated=false}
    probeScratch(ctx, 0, function()
      moveLeaf(ctx, origin, ctx.workspace, ctx.scratch, function()
        prepareScratch(ctx, function()
          moveLeaf(ctx, origin, ctx.scratch, ctx.workspace, function()
            normalizeRoot(ctx, origin, function()
              scratchEmpty(ctx, function()
                read(ctx.workspace, function(final)
                  local after = final[origin.id]
                  if not after or after['app-pid'] ~= origin.pid or after.workspace ~= origin.workspace
                    or not standalone(after) or not pairMatches(expected, links.containing(origin.id)) then
                    abort(ctx, 'Window did not become standalone; inspect this space'); return
                  end
                  links.unlink(origin.id)
                  restoreScratchView(ctx, function(restored)
                    G.lastWorkspaceCleanup = restored
                    if restored then succeed('Window separated') else fail('Window separated, but temporary workspace cleanup failed') end
                  end)
                end, function() abort(ctx, 'Could not verify the returned window') end)
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end
-- AeroSpace swap only targets a direction or dfs neighbour, never a window ID,
-- so an exact swap re-forms this same pair with the roles reversed.
function G.swap(a, b, expected)
  if G.busy then alert('Still arranging the previous split'); return end
  local current = a and b and links.containing(a.id)
  if not samePair(current, a, b) or not pairMatches(expected, current) then
    G.lastResult = false; G.lastError = 'The linked pair changed'
    alert('The linked pair changed; refresh and try again'); return
  end
  local captured={a={id=current.a.id,pid=current.a.pid},b={id=current.b.id,pid=current.b.pid}}
  G.pair(b, a, 'Pair order swapped', captured, true)
end
function G.candidates(origin, cache)
  local choices = {}
  for _, c in ipairs(cache) do
    if c.id ~= origin.id and c.workspace == origin.workspace then
      table.insert(choices, {id=c.id, pid=c.pid, workspace=c.workspace, monitor=c.monitor,
        text=c.text, subText=c.subText, image=c.image})
    end
  end
  table.sort(choices, function(a,b) if a.text ~= b.text then return a.text < b.text end; return a.id < b.id end)
  return choices
end
G.chooser = hs.chooser.new(function(choice)
  local origin = G.pairOrigin
  hs.timer.doAfter(0.12, function()
    if choice then G.pair(origin, choice) elseif origin then focusOrigin(origin, function() end) end
  end)
end):rows(9):width(55):searchSubText(true)
function G.choose(origin)
  if G.busy then alert('Still arranging the previous split'); return end
  if G.chooser:isVisible() then G.chooser:hide(); return end
  origin = origin or G.origin(); if not origin then return end
  G.pairOrigin = origin
  local choices = {}
  for _, c in ipairs(G.candidates(origin, leanmac.picker.cache)) do if valid(c) then table.insert(choices, c) end end
  if #choices == 0 then alert('Open another window in space ' .. origin.workspace .. ' first'); return end
  G.chooser:placeholderText('Pair with… · space ' .. origin.workspace .. ' · current window stays left')
    :query(''):choices(choices):show()
  leanmac.picker.refresh()
end
local menuItems = {
  {id='pair', text='Pair with another window…', subText='⌥P · choose a window in this space'},
  {id='separate', text='Separate this window', subText='⌥⇧P · leave the other split windows intact'},
  {id='zoom', text='Zoom / unzoom this window', subText='⌥F · AeroSpace fullscreen, no macOS Desktop'},
  {id='tiles', text='Show this group side by side / tiled', subText='⌥/ · preserve the grouping tree'},
  {id='stack', text='Stack this group', subText='⌥⇧/ · preserve the grouping tree'},
  {id='balance', text='Balance sizes in this space', subText='⌥⇧= · equalize split widths'},
  {id='float', text='Toggle freeform floating', subText='⌥⇧Space · existing ⌥arrows / edge snapping stay freeform'},
  {id='reset', text='Reset this space to standalone windows…', subText='Confirmation required · removes ALL splits in this space'},
}
G.menu = hs.chooser.new(function(choice)
  local origin = G.menuOrigin
  hs.timer.doAfter(0.12, function()
    if not origin then return end
    focusOrigin(origin, function()
      if not choice then return end
      if choice.id == 'pair' then G.choose(origin); return end
      if choice.id == 'separate' then G.separate(origin); return end
      local commands = {zoom='fullscreen', tiles='layout tiles', stack='layout accordion',
        balance='balance-sizes', float='layout floating tiling'}
      if choice.id == 'reset' then
        if hs.dialog.blockAlert('Reset space ' .. origin.workspace .. '?', 'Remove all split groups in this space? Other spaces and floating windows are unchanged.', 'Reset', 'Cancel') ~= 'Reset' then return end
        run({'flatten-workspace-tree', '--workspace', origin.workspace}, function()
          run({'layout', '--workspace', origin.workspace, '--root', 'v_accordion'})
        end)
      elseif commands[choice.id] then
        -- origin is restored before invoking an existing AeroSpace-owned action.
        local keys = {zoom='alt-f',tiles='alt-slash',stack='alt-shift-slash',balance='alt-shift-equal',float='alt-shift-space'}
        run({'trigger-binding', keys[choice.id], '--mode', 'main'})
      end
    end)
  end)
end):rows(9):width(60):searchSubText(true):placeholderText('Layouts · pair, separate, zoom · Escape cancels')
function G.show()
  if G.busy then alert('Still arranging the previous split'); return end
  if G.menu:isVisible() then G.menu:hide(); return end
  local origin = G.origin(); if not origin then return end
  G.menuOrigin = origin
  G.menu:query(''):choices(menuItems):show()
end
local previousChooserCallback = hs.chooser.globalCallback
hs.chooser.globalCallback = function(chooser, event)
  if chooser ~= G.chooser and chooser ~= G.menu and previousChooserCallback then previousChooserCallback(chooser, event) end
end
G.pairKey = hs.hotkey.bind({'alt'}, 'p', function() G.choose() end)
G.separateKey = hs.hotkey.bind({'alt','shift'}, 'p', function() G.separate() end)
G.menuKey = hs.hotkey.bind({'alt'}, 'g', G.show)
assert(G.pairKey and G.pairKey.enabled and G.separateKey and G.separateKey.enabled and G.menuKey and G.menuKey.enabled,
  'LeanMac layout shortcuts could not be registered')
G.focus = focusOrigin
return G
