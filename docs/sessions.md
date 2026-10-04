# Sessions

Open **Sessions** in Ground Control or use the **✈︎ Hangar menu**. These are immediate actions; the configuration Save buttons do not apply to them.

## Holding Pattern

Choose 15, 30, 60 or 120 minutes in the UI. The Mac stays awake while its display can sleep normally; enable **Keep display awake too** for a presentation or reference screen. Stop from Settings, the menu or `hangar hold stop`. Starting a new hold replaces your previous hold. It affects only Hangar's own sleep assertions.

The CLI accepts whole-minute durations from 1 to 1440. `hangar hold status --json` reports active state, deadline, mode and any error. Stopping is asynchronous and can briefly report `stopping: true`. Expiry, quitting or reloading Hammerspoon releases the assertion. Closing Settings does not stop it. Closing a laptop lid or explicitly choosing Sleep can still sleep the Mac.

## Turnaround

Start a focus round, pause/resume it, or end the session. Default rounds are 25 minutes of focus and 5 minutes of break, with a 15-minute long break after every fourth focus round. Each completed phase waits for you to start the next one.

```sh
hangar focus start --minutes 45 --break-minutes 10 --long-break-minutes 20
hangar focus pause
hangar focus resume
hangar focus next
hangar focus cancel
hangar focus status --json
```

Focus duration is 1–180 minutes, short breaks 1–60, and long breaks 1–120. A paused timer retains its remaining time across reloads. A running timer uses a real deadline, so time spent asleep still counts; after waking, an overdue phase completes once rather than replaying missed rounds.

## Boarding Calls

Enter a reminder and choose a delay in Sessions, or use a preset from the menu. You can inspect and cancel pending reminders in either place. The CLI supports 1–10080 minutes (seven days), up to 20 pending reminders, and one line of up to 280 characters.

```sh
hangar remind add "Check the export" --minutes 15 --json
hangar remind list --json
hangar remind cancel 1
```

Notifications respect macOS notification permissions and Focus settings. They remain in Notification Center until dismissed; clicking one opens Ground Control. Hammerspoon must be running for delivery. If it is closed or the Mac sleeps, overdue reminders are processed when Hangar loads or wakes. Delivery is at most once: state is saved before sending, so a crash at that boundary can lose a notification rather than duplicate it.

Focus and reminder state is private to this Mac in `~/Library/Application Support/LeanMac/Sessions/state.json`. It is not part of dotfiles, shared configuration, releases or installation rollback. Invalid or unreadable state is preserved and reported instead of overwritten. Keep-awake sessions are intentionally not persisted.

Timers use a one-shot deadline and wake events; idle sessions do not run a polling timer.
