#!/usr/bin/env python3
"""Explicit macOS native lifecycle test; uses temporary state and hidden windows.

Run: python3 tests/shelf_native_smoke.py /path/to/hangar-shelf
The helper briefly owns a menu-bar item. No system clipboard or user shelf is used.
"""
import json
import fcntl
import pathlib
import subprocess
import sys
import tempfile
import time


def eventually(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("Native shelf did not reach the expected state")


def main():
    helper = pathlib.Path(sys.argv[1]).resolve()
    processes = []
    with tempfile.TemporaryDirectory(prefix="ApronLifecycle-") as temporary:
        root = pathlib.Path(temporary)
        state = root / "state"
        original = root / "Original 日本語.txt"
        original.write_text("original must survive", encoding="utf-8")
        base = [str(helper), "--state-dir", str(state), "--no-shake"]

        def invoke(*args):
            return subprocess.run([*base, *args], text=True, capture_output=True, timeout=20)

        def start(*args):
            process = subprocess.Popen([*base, "--background", *args], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            processes.append(process)
            return process

        try:
            first = start("--add", str(original))
            manifest = state / "shelves.json"
            eventually(lambda: manifest.exists() or first.poll() is not None)
            assert first.poll() is None, first.stderr.read().decode()
            acknowledgement = invoke("--wait", "--background")
            assert acknowledgement.returncode == 0, acknowledgement.stderr
            receipt = json.loads(acknowledgement.stdout)
            assert receipt["processID"] == first.pid and receipt["visible"] is False, receipt
            assert invoke("--quit").returncode == 0
            first.wait(timeout=10)
            assert not list((state / "Inbox").glob("*.json")), "Quit request poisoned the inbox"

            second = start()
            def resident_has_lock():
                with (state / "instance.lock").open("r+") as lock:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        return True
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    return False
            eventually(resident_has_lock)
            acknowledgement = invoke("--wait", "--background")
            assert acknowledgement.returncode == 0, acknowledgement.stderr
            receipt = json.loads(acknowledgement.stdout)
            assert second.poll() is None and receipt["processID"] == second.pid, receipt
            assert receipt["visible"] is False, "Restarted background shelf became visible"
            assert invoke("--background").returncode == 0

            extra = root / "Second.txt"
            extra.write_text("second", encoding="utf-8")
            acknowledgement = invoke("--wait", "--background", "--add", str(extra))
            receipt = json.loads(acknowledgement.stdout)
            assert acknowledgement.returncode == 0 and receipt["added"] == 1, receipt
            assert receipt["visible"] is False and receipt["processID"] == second.pid, receipt
            saved = manifest.read_bytes()
            failed = invoke("--wait", "--background", "--add", str(root / "missing.txt"))
            receipt = json.loads(failed.stdout)
            assert failed.returncode == 1 and receipt["ok"] is False and receipt["added"] == 0, receipt
            assert saved == manifest.read_bytes(), "Failed import changed persisted state"
            assert original.read_text(encoding="utf-8") == "original must survive"
            assert invoke("--quit").returncode == 0
            second.wait(timeout=10)
            assert not list((state / "Inbox").glob("*.json")), "Second quit request was not consumed"

            # Exercise the CLI launcher path with no resident process.
            launched = invoke("--wait", "--background", "--add", str(extra))
            receipt = json.loads(launched.stdout)
            assert launched.returncode == 0 and receipt["ok"] and receipt["added"] == 0, receipt
            assert receipt["visible"] is False, "Cold synchronous launcher showed the shelf"
            assert invoke("--quit").returncode == 0
            eventually(lambda: not list((state / "Inbox").glob("*.json")))
            print("PASS: native hidden startup/import, quit/restart without poison, single instance, receipt success/failure, persisted-state safety and cold CLI launcher")
        finally:
            invoke("--quit")
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)


if __name__ == "__main__":
    main()
