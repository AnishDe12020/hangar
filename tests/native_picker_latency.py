"""Opt-in before/after commit latency on owned native windows, not user windows.

Measures selection callback -> native exact focus/raises -> focused-ID check.
Picker rendering/physical key dispatch are excluded. Restores original views.
Pass --native-picker with a compiled candidate helper. --dual-display also
checks that a different front app on the other display stays above same-app
siblings of the selected target. All fixtures belong to this test.
"""
import argparse
import json
import selectors
import statistics
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--baseline-kit', type=Path, required=True)
parser.add_argument('--samples', type=int, default=5)
parser.add_argument('--variant', choices=('both', 'before', 'after'), default='both')
parser.add_argument('--profile-helper', action='store_true')
parser.add_argument('--focus-helper', type=Path)
parser.add_argument('--native-picker', type=Path, required=True)
parser.add_argument('--dual-display', action='store_true')
options = parser.parse_args()
KIT = Path(__file__).resolve().parents[1]
AS = '/opt/homebrew/bin/aerospace'
HS = '/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs'
FORMAT = '%{window-id} %{app-pid} %{workspace} %{window-parent-container-layout}'


def run(*args):
    return subprocess.check_output(args, text=True, timeout=30).strip()


def hs(code):
    return json.loads(run(HS, '-t', '10', '-c', code).splitlines()[-1])


def rows():
    return json.loads(run(AS, 'list-windows', '--all', '--format', FORMAT, '--json'))


def emit(label, result):
    print(json.dumps({'check': label, 'result': result}), flush=True)


def await_state(code, accept, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = hs(code)
        except subprocess.CalledProcessError as error:
            if error.returncode != -6:
                raise
            # Retry only this read-only observation after the hs CLI client
            # crashes, never a setup, mutation or focus request.
            continue
        if accept(result):
            return result
        time.sleep(0.04)
    raise RuntimeError(('Timed out', result))


before = rows()
views = json.loads(run(AS, 'list-workspaces', '--all', '--format',
                      '%{workspace} %{workspace-is-visible} %{workspace-is-focused}', '--json'))
origin = hs('local w=hs.window.focusedWindow(); return hs.json.encode({id=w and w:id(),pid=w and w:pid()})')
if not isinstance(origin, dict):
    origin = {}
if not origin.get('id') or not origin.get('pid'):
    raise RuntimeError('Unlock the Mac and focus a normal app window before this live test')
emit('original-state', {'windows': before, 'views': views, 'focus': origin})
fixture = subprocess.Popen(['/private/tmp/leanmac-pair-native-regression'], stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
workspace = 'leanmac-latency-' + str(fixture.pid)
other_fixture = None
other_ids = []
try:
    with selectors.DefaultSelector() as selector:
        selector.register(fixture.stdout, selectors.EVENT_READ)
        assert selector.select(10), 'Fixture startup timed out'
        ids = [entry['id'] for entry in json.loads(fixture.stdout.readline())]
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        registered = {w['window-id'] for w in rows() if w['app-pid'] == fixture.pid}
        if set(ids) <= registered:
            break
        time.sleep(0.2)
    assert set(ids) <= registered
    for identity in ids:
        run(AS, 'move-node-to-workspace', '--window-id', str(identity), workspace)
    run(AS, 'layout', '--window-id', str(ids[0]), '--root', 'v_accordion')
    run(AS, 'join-with', '--window-id', str(ids[1]), 'up')
    layout = {w['window-id']: w for w in rows() if w['app-pid'] == fixture.pid}
    assert all(layout[i]['window-parent-container-layout'] == 'h_tiles' for i in ids[:2]), layout
    assert all(layout[i]['window-parent-container-layout'] == 'v_accordion' for i in ids[2:]), layout
    if options.dual_display:
        monitors = json.loads(run(AS, 'list-monitors', '--format', '%{monitor-id} %{monitor-name}', '--json'))
        assert len(monitors) == 2, 'This regression requires exactly two displays'
        run(AS, 'move-workspace-to-monitor', '--workspace', workspace, str(monitors[0]['monitor-id']))
        other_workspace = workspace + '-other'
        for identity in ids[3:]:
            run(AS, 'move-node-to-workspace', '--window-id', str(identity), other_workspace)
        run(AS, 'move-workspace-to-monitor', '--workspace', other_workspace, str(monitors[1]['monitor-id']))
        other_fixture = subprocess.Popen(['/private/tmp/leanmac-pair-native-regression'], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        with selectors.DefaultSelector() as selector:
            selector.register(other_fixture.stdout, selectors.EVENT_READ)
            assert selector.select(10), 'Other-display fixture startup timed out'
            other_ids = [entry['id'] for entry in json.loads(other_fixture.stdout.readline())]
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            registered = {w['window-id'] for w in rows() if w['app-pid'] == other_fixture.pid}
            if set(other_ids) <= registered:
                break
            time.sleep(0.2)
        assert set(other_ids) <= registered
        for identity in other_ids:
            run(AS, 'move-node-to-workspace', '--window-id', str(identity), other_workspace)
        run(AS, 'layout', '--window-id', str(other_ids[0]), '--root', 'v_accordion')
        run(AS, 'workspace', other_workspace)
    run(AS, 'focus', '--window-id', str(ids[2]))
    for label, kit in [('before', options.baseline_kit), ('after', KIT)]:
        if options.variant != 'both' and options.variant != label:
            continue
        setup = r'''
local kit=KIT_PATH
local object={enabled=true}
setmetatable(object,{__index=function() return function(self) return self end end})
local t={ids=IDS,pid=FIXTURE_PID,results={},otherIDs=OTHER_IDS,otherPID=OTHER_PID}
local fakeHS=setmetatable({shutdownCallback=false,
  hotkey={bind=function() return object end},
  eventtap=setmetatable({new=function() return object end},{__index=hs.eventtap}),
  axuielement=setmetatable({applicationElementForPID=function() return nil end},{__index=hs.axuielement}),
  alert={show=function(message) t.error=message end}}, {__index=hs})
t.observe=function(code,out,err)
    if t.pending then
      local pending=t.pending
      local completed=hs.timer.absoluteTime()
      local result={callbackMs=(completed-pending.began)/1e6,attempts=0,
        kind=pending.kind,metrics=t.picker.lastFocus,expectedID=pending.id,exitCode=code}
      result.processSeconds=tonumber((err or ''):match('real%s+([%d.]+)'))
      local decoded,timing=pcall(hs.json.decode,out)
      if decoded then result.nativeTiming=timing end
      local function verify()
        if t.pending~=pending then return end
        local front=hs.window.focusedWindow()
        result.frontID=front and front:id(); result.frontPID=front and front:pid()
        result.ok=code==0 and result.frontID==pending.id and result.frontPID==t.pid
        result.attempts=result.attempts+1
        if pending.kind=='pair' then
          local top={}
          for _,w in ipairs(hs.window.list(false)) do
            local id=w.kCGWindowNumber
            if w.kCGWindowOwnerPID==t.pid and w.kCGWindowIsOnscreen and (id==t.ids[1] or id==t.ids[2] or id==t.ids[3]) and #top<2 then top[#top+1]=id end
          end
          result.pairFronts=top
          result.ok=result.ok and #top==2 and ((top[1]==t.ids[1] and top[2]==t.ids[2]) or (top[1]==t.ids[2] and top[2]==t.ids[1]))
        end
        if #t.otherIDs>0 then
          local candidates={[t.ids[4]]=true,[t.ids[5]]=true}
          for _,id in ipairs(t.otherIDs) do candidates[id]=true end
          for _,w in ipairs(hs.window.list(false)) do
            if candidates[w.kCGWindowNumber] and w.kCGWindowIsOnscreen then
              result.otherFrontID=w.kCGWindowNumber; result.otherFrontPID=w.kCGWindowOwnerPID; break
            end
          end
          result.ok=result.ok and result.otherFrontID==t.otherIDs[1] and result.otherFrontPID==t.otherPID
        end
        result.ms=(hs.timer.absoluteTime()-pending.began)/1e6
        if result.ok or hs.timer.absoluteTime()-completed>500000000 then
          t.results[#t.results+1]=result; t.pending=nil
        else t.verifyTimer=hs.timer.doAfter(0.01,verify) end
      end
      t.verifyTimer=hs.timer.doAfter(0,verify)
    end
end
fakeHS.task={new=function(command,callback,third,fourth)
  local args=fourth or third
  if args[1]=='subscribe' then return object end
  local function finished(code,out,err)
    callback(code,out,err)
    if command:match('/leanmac%-window%-focus$') then t.observe(code,out,err) end
  end
  if PROFILE_HELPER and command:match('/leanmac%-window%-focus$') then
    local wrapped={'-p',FOCUS_HELPER or command}; for _,arg in ipairs(args) do wrapped[#wrapped+1]=arg end
    return hs.task.new('/usr/bin/time',finished,wrapped)
  end
  if command:match('/leanmac%-picker$') then command=NATIVE_PICKER end
  if fourth then return hs.task.new(command,finished,third,fourth) end
  return hs.task.new(command,finished,third)
end}
local linkEnv=setmetatable({hs={settings={get=function() return {} end,set=function() end}}},{__index=_G})
local links=assert(loadfile(kit..'/config/window-links.lua','t',linkEnv))()
links.link({id=t.ids[1],pid=t.pid},{id=t.ids[2],pid=t.pid})
local env=setmetatable({hs=fakeHS,leanmac={groups={busy=false},overview={scheduleRefresh=function() end}},
  require=function(name)
    if name=='window-links' then return links end
    if name=='picker-panel' then return {new=function(callback)
      t.commit=callback
      local panelEnv=setmetatable({hs=fakeHS},{__index=_G})
      local M=assert(loadfile(kit..'/config/picker-panel.lua','t',panelEnv))()
      local panel=M.new(callback)
      if panel.focus then
        local original=panel.focus
        function panel:focus(request,done)
          return original(self,request,function(code,out,err,native)
            done(code,out,err,native); t.observe(code,out,err)
          end)
        end
      end
      return panel
    end} end
    return require(name)
  end},{__index=_G})
env._G=env
t.stop=function()
  if t.verifyTimer then t.verifyTimer:stop() end
  if fakeHS.shutdownCallback then fakeHS.shutdownCallback() end
end
leanmacLatency=t
t.picker=assert(loadfile(kit..'/config/window-picker.lua','t',env))()
return hs.json.encode({started=true})
'''.replace('KIT_PATH', json.dumps(str(kit))).replace('OTHER_IDS', '{' + ','.join(map(str, other_ids)) + '}').replace('OTHER_PID', str(other_fixture.pid) if other_fixture else 'nil').replace('IDS', '{' + ','.join(map(str, ids)) + '}').replace('FIXTURE_PID', str(fixture.pid)).replace('PROFILE_HELPER', str(options.profile_helper).lower()).replace('FOCUS_HELPER', json.dumps(str(options.focus_helper)) if options.focus_helper else 'nil').replace('NATIVE_PICKER',json.dumps(str(options.native_picker)))
        hs(setup)
        await_state('local t=leanmacLatency; return hs.json.encode({ready=(t.picker.panel.ready and t.picker.byID and t.picker.byID[t.ids[1]]~=nil and t.picker.pairPartner[t.ids[1]]==t.ids[2])==true})', lambda s: s['ready'])
        for kind in ('single', 'pair'):
            for sample in range(options.samples):
                target = ids[2] if kind == 'single' else ids[sample % 2]
                start_id = ids[0] if kind == 'single' else ids[2]
                run(AS, 'focus', '--window-id', str(start_id))
                await_state('local w=hs.window.focusedWindow(); return hs.json.encode({id=w and w:id()})',
                            lambda state: state.get('id') == start_id)
                if other_fixture:
                    # A second app is frontmost on the other display, above two
                    # same-app siblings of the target. Exact switching must not
                    # activate those siblings across the monitor boundary.
                    run(AS, 'focus', '--window-id', str(other_ids[0]))
                    await_state('local w=hs.window.focusedWindow(); return hs.json.encode({id=w and w:id()})',
                                lambda state: state.get('id') == other_ids[0])
                hs('local t=leanmacLatency; local p=t.picker; '
                   f'local choice=assert(p.byID[{target}]); local kind={json.dumps(kind)}; '
                   'local members=kind=="pair" and {p.byID[t.ids[1]],p.byID[t.ids[2]]} or {choice}; '
                   't.pending={began=hs.timer.absoluteTime(),id=choice.id,kind=kind}; t.error=nil; '
                   't.commit(choice,nil,members); return hs.json.encode({started=true})')
                result = await_state('local t=leanmacLatency; return hs.json.encode({done=t.pending==nil,result=t.results[#t.results],error=t.error})', lambda s: s['done'] or s.get('error'))
                emit(label + '-' + kind, result)
                assert result['done'] and result['result']['ok'], result
        results = hs('return hs.json.encode(leanmacLatency.results)')
        for kind in ('single', 'pair'):
            times = [r['ms'] for r in results if r['kind'] == kind]
            emit(label + '-' + kind + '-summary', {'median_ms': round(statistics.median(times), 2),
                 'min_ms': round(min(times), 2), 'max_ms': round(max(times), 2), 'samples': len(times)})
        hs('leanmacLatency.stop(); leanmacLatency=nil; return hs.json.encode({stopped=true})')
finally:
    cleanup_errors = []
    try:
        hs('if leanmacLatency then leanmacLatency.stop(); leanmacLatency=nil end; return hs.json.encode({stopped=true})')
    except Exception as error:
        cleanup_errors.append('Isolated picker cleanup: ' + str(error))
    fixture.stdin.close()
    try:
        fixture.wait(timeout=5)
    except subprocess.TimeoutExpired:
        fixture.terminate(); fixture.wait(timeout=5)
    if other_fixture:
        other_fixture.stdin.close()
        try:
            other_fixture.wait(timeout=5)
        except subprocess.TimeoutExpired:
            other_fixture.terminate(); other_fixture.wait(timeout=5)
    try:
        for view in sorted((v for v in views if v['workspace-is-visible']), key=lambda v: v['workspace-is-focused']):
            run(AS, 'workspace', view['workspace'])
        after = {w['window-id']: w for w in rows()}
        if origin.get('id') in after and after[origin['id']]['app-pid'] == origin['pid']:
            run(AS, 'focus', '--window-id', str(origin['id']))
        moved = [w['window-id'] for w in before if w['window-id'] in after and w['app-pid'] == after[w['window-id']]['app-pid'] and w['workspace'] != after[w['window-id']]['workspace']]
        assert not moved, ('Non-fixture windows moved', moved)
    except Exception as error:
        cleanup_errors.append('Workspace/focus verification: ' + str(error))
    emit('cleanup', {'fixtureClosed': fixture.poll() is not None,
                     'otherFixtureClosed': not other_fixture or other_fixture.poll() is not None, 'errors': cleanup_errors})
    if cleanup_errors:
        raise RuntimeError(cleanup_errors)
