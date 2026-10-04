"""Exercise the compiled AppKit process over its real pipes (requires a GUI session).

Does not activate real app windows or alter AeroSpace layouts. --preview leaves
the fixture panel open briefly for visual inspection; Escape dismisses it.
"""
import json
import os
import selectors
import subprocess
import sys
import time

executable = sys.argv[1]
preview = '--preview' in sys.argv
process = subprocess.Popen([executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
buffer = b''
pending = []
sequence = 0

def send(action, session=1, **payload):
    global sequence
    sequence += 1
    process.stdin.write((json.dumps(dict(action=action, session=session, sequence=sequence, **payload))+'\n').encode())
    process.stdin.flush()
    return sequence

def receive(action, timeout=4):
    global buffer
    deadline = time.monotonic()+timeout
    while time.monotonic() < deadline:
        while pending:
            item = pending.pop(0)
            if item['action'] == action:
                return item
        for key, _ in selector.select(max(0, deadline-time.monotonic())):
            data = os.read(key.fd, 65536)
            if not data:
                raise RuntimeError('Helper exited: '+process.stderr.read().decode())
            buffer += data
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                pending.append(json.loads(line))
    raise TimeoutError(action)

def receive_ack(sequence):
    while True:
        packet = receive('ack')
        if packet['sequence'] == sequence:
            return packet

windows = [
    dict(id=1, pid=101, app='Aside', title='LeanMac · Design & documentation', bundle='at.studio.AsideBrowser', workspace='1', partner=3),
    dict(id=2, pid=102, app='ChatGPT', title='Building a better window switcher', bundle='com.openai.chat', workspace='1'),
    dict(id=3, pid=103, app='Ghostty', title='~/leanmac — zsh', bundle='com.mitchellh.ghostty', workspace='1', partner=1),
    dict(id=4, pid=104, app='Obsidian', title='Operating Systems · Lecture notes', bundle='md.obsidian', workspace='2'),
    dict(id=5, pid=105, app='Zed', title='coursework — main.c', bundle='dev.zed.Zed', workspace='2'),
    dict(id=6, pid=106, app='Aside', title='Google Drive · Study materials', bundle='at.studio.AsideBrowser', workspace='2'),
    dict(id=7, pid=107, app='WhatsApp', title='Chats', bundle='net.whatsapp.WhatsApp', workspace='3'),
]
for w in windows:
    w['monitor'] = 'External Display' if w['workspace'] in ('1','2') else 'Built-in Retina Display'
    w['visible'] = w['workspace'] in ('1','3')
frame = dict(x=0, y=25, w=1470, h=875)
try:
    assert receive('ready')['action'] == 'ready'
    # Bogus identities exercise validation only; they must never focus a real window.
    seq = send('focus', session=0, id=0, pid=0, restores=[])
    rejected = receive('focused')
    assert rejected['sequence'] == seq and rejected['ok'] is False
    assert receive_ack(seq)['showing'] is False
    send('warm', windows=windows)
    send('show', windows=windows, frame=frame, hold=False, step=0, originWorkspace='1')
    shown = receive('shown')
    assert (shown['rows'], shown['windows'], shown['id']) == (6,7,1), shown
    assert shown['ids'] == [1,3] and shown['width'] == 620 and shown['height'] <= 520
    timings = [shown['elapsedMs']]
    seq = send('focus', session=1, id=0, pid=0, restores=[])
    rejected = receive('focused')
    assert rejected['sequence'] == seq and rejected['ok'] is False and rejected['error'] == 'panel visible'
    assert receive_ack(seq)['showing'] is True
    if preview:
        print('Preview ready', flush=True)
        time.sleep(50)
    else:
        send('navigate', axis='horizontal', delta=1)
        assert receive('selection')['id'] == 2
        send('navigate', axis='horizontal', delta=-1)
        assert receive('selection')['id'] == 1
        send('navigate', axis='vertical', delta=1)
        assert receive('selection')['id'] == 2
        send('navigate', axis='vertical', delta=-1)
        assert receive('selection')['id'] == 1
        send('step', delta=1)
        assert receive('selection')['id'] == 2  # next group, skipping the other pair member
        send('step', delta=-1)
        assert receive('selection')['ids'] == [1,3]
        send('confirm')
        chosen = receive('choose')
        assert chosen['hidden'] is True, chosen
        assert (chosen['id'],chosen['pid'],chosen['ids']) == (1,101,[1,3])
        send('show', session=2, windows=windows, frame=frame, hold=True, step=-1)
        assert receive('shown')['id'] == 7
        send('step', session=1, delta=1)  # obsolete session must have no effect
        send('confirm', session=2)
        assert receive('choose')['id'] == 7
        # Pipe ordering: a fast open, step, commit must target the final selection.
        send('show', session=3, windows=windows, frame=frame, hold=False, step=0)
        send('step', session=3, delta=2)
        send('confirm', session=3)
        assert receive('choose')['id'] == 4
        # MRU picks the right member as focus, without adding another Tab stop.
        reverse_mru = [windows[2], windows[0], windows[1], *windows[3:]]
        send('show', session=10, windows=reverse_mru, frame=frame, hold=False, step=0)
        assert receive('shown')['id'] == 3
        send('confirm', session=10)
        chosen = receive('choose')
        assert chosen['id'] == 3 and set(chosen['ids']) == {1,3}
        send('show', session=11, windows=reverse_mru, frame=frame, hold=True, step=1)
        assert receive('shown')['id'] == 2
        send('hide', session=11)
        for session in range(4,9):
            send('show', session=session, windows=windows, frame=frame, hold=False, step=0)
            timings.append(receive('shown')['elapsedMs'])
            send('hide', session=session)
        seq = send('show', session=20, windows=windows, frame=frame, hold=False, step=0)
        assert receive('shown')['session'] == 20
        assert receive_ack(seq)['showing'] is True
        seq = send('hide', session=20)
        assert receive_ack(seq)['showing'] is False
        seq = send('confirm', session=20)  # closed panel still acknowledges consumption
        assert receive_ack(seq)['showing'] is False
        seq = send('step', session=19, delta=1)  # stale commands must also release the pipe
        assert receive_ack(seq)['session'] == 19
        seq = send('warm', session=21, windows=windows)
        assert receive_ack(seq)['showing'] is False
        print('Native protocol passed: atomic groups, MRU member, whole-group Tab skip, compact bounds, reverse, wrap, stale session, rapid commit, reopen, acknowledgements including closed/stale/warm commands')
        print('Native render milliseconds:', [round(t,2) for t in timings])
finally:
    process.stdin.close()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.terminate(); process.wait(timeout=3)
    selector.close()
