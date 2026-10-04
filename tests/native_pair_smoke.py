"""Opt-in live regression: manipulates only this process's disposable windows.

Build pair_native_fixture.swift first. Original visible workspaces are restored
and the fixture is terminated in finally; existing app windows are never moved.
"""
import json
import os
from pathlib import Path
import selectors
import subprocess
import time

KIT = Path(__file__).resolve().parents[1]
AS = '/opt/homebrew/bin/aerospace'
HS = '/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs'
FIXTURE = '/private/tmp/leanmac-pair-native-regression'
FORMAT = '%{window-id} %{app-pid} %{workspace} %{window-parent-container-layout} %{workspace-root-container-layout}'


def run(*args):
    return subprocess.check_output(args, text=True, timeout=30).strip()


def hs(code):
    output = run(HS, '-c', code)
    return json.loads(output.splitlines()[-1])


def rows():
    return json.loads(run(AS, 'list-windows', '--all', '--format', FORMAT, '--json'))


def emit(label, value):
    print(json.dumps({'check': label, 'result': value}), flush=True)


def line(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(12):
            raise RuntimeError('Fixture did not respond')
        return json.loads(process.stdout.readline())


before = rows()
visible = json.loads(run(AS, 'list-workspaces', '--all', '--format',
                        '%{workspace} %{workspace-is-visible} %{workspace-is-focused}', '--json'))
focus = hs('return hs.json.encode({id=hs.window.focusedWindow() and hs.window.focusedWindow():id() or false})')['id']
fixture = subprocess.Popen([FIXTURE], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True, bufsize=1)
ids = []
workspace = 'leanmac-regression-' + str(fixture.pid)
try:
    ids = [entry['id'] for entry in line(fixture)]
    assert len(ids) == 5
    registered = {}
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        registered = {row['window-id']: row for row in rows() if row['app-pid'] == fixture.pid}
        if set(ids).issubset(registered):
            break
        time.sleep(0.2)
    assert set(ids).issubset(registered), ('AeroSpace did not register fixture windows', ids, registered)
    for identity in ids:
        current = registered[identity]
        assert current['app-pid'] == fixture.pid
        run(AS, 'move-node-to-workspace', '--window-id', str(identity), workspace)
    # Exercise the user's dual-display case: pair on the external display,
    # while a new unassigned scratch defaults to the main/built-in display.
    monitors = json.loads(run(AS, 'list-monitors', '--format', '%{monitor-id} %{monitor-name}', '--json'))
    external = next((m for m in monitors if 'Built-in' not in m['monitor-name']), monitors[0])
    run(AS, 'move-workspace-to-monitor', '--workspace', workspace, str(external['monitor-id']))
    run(AS, 'workspace', workspace)
    lua = r'''
local object={enabled=true}
setmetatable(object,{__index=function() return function(self) return self end end})
local fakeHS=setmetatable({hotkey={bind=function() return object end},
  chooser={new=function() return object end},alert={show=function() end}}, {__index=hs})
local linkEnv=setmetatable({hs={settings={get=function() return {} end,set=function() end}}},{__index=_G})
local kit=KIT_PATH
local links=assert(loadfile(kit..'/config/window-links.lua','t',linkEnv))()
local private={picker={cache={},byID={},refresh=function() end},overview={scheduleRefresh=function() end}}
local trace={}
local groups
local runtime=require('leanmac-runtime')
local tracedRuntime={aerospace=runtime.aerospace,run=function(command,args,done,seconds)
  local entry={command=command,args=args,started=hs.timer.secondsSinceEpoch()}
  trace[#trace+1]=entry
  local function dispatch()
  if args[1]=='join-with' and leanmacPairRegression and leanmacPairRegression.failJoin then
    leanmacPairRegression.failJoin=false
    entry.code=1; entry.elapsed=hs.timer.secondsSinceEpoch()-entry.started
    done(1,'','Injected disposable join failure'); return
  end
  return runtime.run(command,args,function(code,out,err)
    entry.code=code;entry.elapsed=hs.timer.secondsSinceEpoch()-entry.started
    done(code,out,err)
  end,seconds)
  end
  if args[1]=='join-with' and leanmacPairRegression and leanmacPairRegression.forceScratchVisible then
    leanmacPairRegression.forceScratchVisible=false
    return runtime.run(runtime.aerospace,{'workspace',groups.lastScratch},function(code)
      assert(code==0, 'Could not expose the disposable scratch workspace')
      dispatch()
    end)
  end
  return dispatch()
end}
local env=setmetatable({hs=fakeHS,leanmac=private,require=function(name)
  if name=='window-links' then return links end
  if name=='leanmac-runtime' then return tracedRuntime end; return require(name)
end},{__index=_G})
groups=assert(loadfile(kit..'/config/window-groups.lua','t',env))()
private.groups=groups
leanmacPairRegression={groups=groups,links=links,private=private,environment=env,trace=trace,ids=IDS,pid=PID,workspace=WORKSPACE}
function leanmacPairRegression.member(id)
  local w=hs.window.get(id)
  return {id=id,pid=PID,workspace=WORKSPACE,monitor=w:screen():name(),restores={}}
end
return hs.json.encode({ready=true})
'''.replace('KIT_PATH', json.dumps(str(KIT))).replace('IDS', '{' + ','.join(map(str, ids)) + '}')
    lua = lua.replace('PID', str(fixture.pid)).replace('WORKSPACE', json.dumps(workspace))
    assert hs(lua)['ready']

    def action(name, first, second=None, expose_scratch=False, fail_join=False):
        started = time.monotonic()
        args = f't.member({first})'
        if second is not None:
            args += f',t.member({second})'
        before_views = json.loads(run(AS, 'list-workspaces', '--all', '--format',
                                     '%{workspace} %{monitor-id} %{workspace-is-visible}', '--json'))
        hs(f'local t=leanmacPairRegression; t.forceScratchVisible={str(expose_scratch).lower()}; t.failJoin={str(fail_join).lower()}; t.groups.{name}({args}); return hs.json.encode({{started=true}})')
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            result = hs('local t=leanmacPairRegression; return hs.json.encode({busy=t.groups.busy,ok=t.groups.lastResult,error=t.groups.lastError,pairs=t.links.pairs})')
            if not result['busy']:
                assert result.get('ok') is (not fail_join), result
                time.sleep(0.25)
                result['seconds'] = round(time.monotonic() - started, 3)
                after_views = json.loads(run(AS, 'list-workspaces', '--all', '--format',
                                            '%{workspace} %{monitor-id} %{workspace-is-visible}', '--json'))
                assert not any(v['workspace'].startswith('LMPAIR') for v in after_views), after_views
                before_map = {v['monitor-id']: v['workspace'] for v in before_views if v['workspace-is-visible']}
                after_map = {v['monitor-id']: v['workspace'] for v in after_views if v['workspace-is-visible']}
                assert after_map == before_map, (before_map, after_map)
                if name in ('pair', 'swap') and not fail_join:
                    expected_focus = first if name == 'pair' else second
                    native_focus = hs('return hs.json.encode({id=hs.window.focusedWindow() and hs.window.focusedWindow():id()})')['id']
                    aero_focus = json.loads(run(AS, 'list-windows', '--focused', '--format', FORMAT, '--json'))
                    assert native_focus == expected_focus, (native_focus, expected_focus)
                    assert len(aero_focus) == 1 and aero_focus[0]['window-id'] == expected_focus and aero_focus[0]['workspace'] == workspace, aero_focus
                emit(name, result)
                return result
            time.sleep(0.2)
        emit('timeout trace', hs('return hs.json.encode(leanmacPairRegression.trace)'))
        raise RuntimeError('Group action did not settle')

    def layout():
        result = {r['window-id']: r for r in rows() if r['app-pid'] == fixture.pid}
        assert set(result) == set(ids)
        assert all(r['workspace'] == workspace for r in result.values()), result
        return result

    def frames():
        fixture.stdin.write('frames\n'); fixture.stdin.flush()
        return {r['id']: r for r in line(fixture)}

    def isolated_pair(first, second, excluded):
        # Change only the chosen parent layout. A bystander must not follow it.
        run(AS, 'layout', '--window-id', str(first), 'h_accordion')
        current = layout()
        assert current[first]['window-parent-container-layout'] == 'h_accordion'
        assert current[second]['window-parent-container-layout'] == 'h_accordion'
        assert all(current[i]['window-parent-container-layout'] != 'h_accordion' for i in excluded), current
        run(AS, 'layout', '--window-id', str(first), 'h_tiles')

    a, b, c, d, e = ids
    parking = workspace + '-parking'

    def backend_checks():
        action('pair', a, b, expose_scratch=True)
        action('pair', c, d)
        isolated_pair(a, b, [c, d, e])
        isolated_pair(c, d, [a, b, e])
        assert layout()[e]['window-parent-container-layout'] == 'v_accordion'
        left, right = a, b
        for _ in range(1 if os.environ.get('LEANMAC_SMOKE_QUICK') else 4):
            action('swap', left, right)
            left, right = right, left
            f = frames()
            assert f[left]['x'] + f[left]['w'] <= f[right]['x'] + 3, f
            isolated_pair(left, right, [c, d, e])
            isolated_pair(c, d, [a, b, e])
        action('separate', a)
        current = layout()
        assert current[a]['window-parent-container-layout'] == 'v_accordion', current
        assert current[b]['window-parent-container-layout'] == 'v_accordion', current
        isolated_pair(c, d, [a, b, e])
        action('pair', a, e)
        isolated_pair(a, e, [b, c, d])
        isolated_pair(c, d, [a, b, e])
        run(AS, 'layout', '--window-id', str(a), 'h_accordion')
        action('swap', a, e)
        current = layout()
        assert current[a]['window-parent-container-layout'] == 'h_accordion'
        assert current[e]['window-parent-container-layout'] == 'h_accordion'
        assert current[c]['window-parent-container-layout'] == 'h_tiles'
        emit('PASS: repeated swaps, isolation, separation, stacked swap', ids)
        # Normalization promotes the untouched C/D pair to a horizontal ROOT when
        # all the other leaves leave. Rebuilding A/B must preserve that old root.
        for identity in (a, b, e):
            run(AS, 'move-node-to-workspace', '--window-id', str(identity), parking)
        assert next(r for r in rows() if r['window-id'] == c)['workspace-root-container-layout'] == 'h_tiles'
        for identity in (a, b):
            run(AS, 'move-node-to-workspace', '--window-id', str(identity), workspace)
        action('pair', a, b)
        run(AS, 'move-node-to-workspace', '--window-id', str(e), workspace)
        isolated_pair(a, b, [c, d, e])
        isolated_pair(c, d, [a, b, e])
        emit('PASS: horizontal-root recovery preserved the other pair', True)
        for identity in (a, b, e):
            run(AS, 'move-node-to-workspace', '--window-id', str(identity), parking)
        action('separate', c)
        current = {r['window-id']: r for r in rows()}
        assert all(current[i]['window-parent-container-layout'] == 'v_accordion' for i in (c, d))
        for identity in (a, b, e):
            run(AS, 'move-node-to-workspace', '--window-id', str(identity), workspace)
        layout()
        emit('PASS: separation when the pair was the entire workspace', True)
        action('pair', a, b, expose_scratch=True, fail_join=True)
        emit('PASS: failure path restored both displays and removed empty scratch', True)

    if not os.environ.get('LEANMAC_SMOKE_OVERVIEW_ONLY'):
        backend_checks()
    # Open the real native overview on another owned workspace, then arrange
    # A/B from its board. Re-show and Escape must follow the pair, not the opener.
    run(AS, 'move-node-to-workspace', '--window-id', str(e), parking)
    run(AS, 'focus', '--window-id', str(e))
    hs('local t=leanmacPairRegression; t.private.picker.filterNativeTabs=function(rows) return rows end; '
       't.private.picker.byID[t.ids[5]]=t.member(t.ids[5]); '
       f't.private.overview=assert(loadfile({json.dumps(str(KIT / "config/workspace-overview.lua"))},"t",t.environment))(); '
       't.private.overview.show(); return hs.json.encode({started=true})')
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        board = hs('local b=leanmacPairRegression.private.overview; return hs.json.encode({ready=b.ready,version=b.version,visible=b.visible})')
        if board['ready'] and board['version'] > 0:
            break
        time.sleep(0.2)
    assert board['ready'] and board['visible'] and board['version'] > 0, board
    hs('local t=leanmacPairRegression; local b=t.private.overview; '
       'b.handle({action="pair",ids={t.ids[1],t.ids[2]},session=b.session,version=b.version}); '
       'return hs.json.encode({started=true})')
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        board = hs('local b=leanmacPairRegression.private.overview; return hs.json.encode({busy=b.busy,visible=b.visible,ready=b.ready,origin=b.origin,message=b.message,pid=b.task and b.task:pid()})')
        if not board['busy'] and (not board['visible'] or board['ready']):
            break
        time.sleep(0.2)
    assert not board['busy'] and board['visible'] and board['origin']['id'] == a, board
    # Utility NSPanel windows need not appear in AeroSpace's tiled inventory.
    # Verify the actual focused workspace and the freshly launched native app.
    active = json.loads(run(AS, 'list-workspaces', '--focused', '--json'))
    assert len(active) == 1 and active[0]['workspace'] == workspace, (board, active)
    native_board = hs('return hs.json.encode({pid=hs.application.frontmostApplication():pid()})')
    assert native_board['pid'] == board['pid'], (board, native_board)
    hs('leanmacPairRegression.private.overview.hide(true); return hs.json.encode({closed=true})')
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        focused = hs('return hs.json.encode({id=hs.window.focusedWindow() and hs.window.focusedWindow():id()})')
        if focused['id'] == a:
            break
        time.sleep(0.2)
    assert focused['id'] == a, focused
    aero_focus = json.loads(run(AS, 'list-windows', '--focused', '--format', FORMAT, '--json'))
    assert len(aero_focus) == 1 and aero_focus[0]['window-id'] == a and aero_focus[0]['workspace'] == workspace, aero_focus
    emit('PASS: native overview reopened on pair space and Escape restored exact pair member', True)
finally:
    try:
        hs('local t=leanmacPairRegression; local b=t and t.private.overview; '
           'if b and b.hide then b.busy=false; b.hide(false) end; return hs.json.encode({closed=true})')
    except Exception as error:
        emit('overview cleanup warning', str(error))
    if fixture.stdin:
        fixture.stdin.close()
    try:
        fixture.wait(timeout=5)
    except subprocess.TimeoutExpired:
        fixture.terminate(); fixture.wait(timeout=5)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if not any(r['app-pid'] == fixture.pid for r in rows()):
            break
        time.sleep(0.2)
    try:
        hs('leanmacPairRegression=nil; return hs.json.encode({cleared=true})')
    except Exception as error:
        emit('test-state cleanup warning', str(error))
    # Restore both monitors, restoring the originally focused workspace last.
    for entry in sorted((v for v in visible if v['workspace-is-visible']),
                        key=lambda v: v['workspace-is-focused']):
        run(AS, 'workspace', entry['workspace'])
    if focus and any(r['window-id'] == focus for r in rows()):
        run(AS, 'focus', '--window-id', str(focus))
    after = {r['window-id']: r for r in rows()}
    moved = [r['window-id'] for r in before if r['window-id'] in after
             and r['workspace'] != after[r['window-id']]['workspace']]
    assert not moved, ('Non-fixture workspace assignments changed', moved)
    assert not any(r['app-pid'] == fixture.pid for r in after.values())
    emit('cleanup: fixture closed, original workspace assignments retained', True)
