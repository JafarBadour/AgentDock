# Archon — implementation decisions

Companion to the design doc. That says what Archon should be; this records
what was actually built, and the choices made where the design left room.
Written as it was built, for review — anything here is changeable.

Status: **foundation complete, not yet a working manager.** See [Open](#open).

---

## The shape of it

Archon is **an ordinary chat** on a host you pick, with a skill that makes it
behave like a manager and a `archon` command that gives it reach.

That was the biggest decision. The design says Archon's LLM is "a session on
the host, the same kind a regular AgentDock agent uses", and taking that
literally pays for itself: transcript, streaming, reconnect, multi-device sync
and the permission system all already work and are not reimplemented. The
alternative — a bespoke Archon runtime — duplicates ~3000 lines of chat
machinery and every reconnect edge case.

Consequences:

| | |
|---|---|
| Archon's chat id | reserved (`archon`), not a schema column — only one is active at a time, and moving hosts repoints its row rather than making a second |
| Hidden from the Agents list | filtered where the list is built, not in the database, so storage and catalog sync keep treating it as the ordinary chat it is |
| No Fork button | forking the manager would make a second manager |
| Its workspace | `~/.agentdock/archon/workspace`, its own folder — Archon directs agents and never executes, so it has no reason to sit inside code it might be asked about but must not touch |

## Permissions

**Archon acts with the user's permissions. It is not a second authority.**

- **Allow all** — Archon may command the agent.
- **Ask** — the user wants to approve each tool on their own device. Archon is
  not that device, so it may look but not touch.
- **Not recorded** — treated as Ask.

That last row is a decision. Records written before this feature predate the
field, and an unknown permission is not a granted one. It fails closed; the
alternative would have silently handed Archon every pre-existing agent.

The choice was **never written down** before this — the app kept it per session
and passed it to `agents.ensure`, which dropped it. The daemon now records it
on the agent record, which is what the gate reads.

An agent Archon cannot drive is **still listed**, with the reason. Hiding it
would leave Archon unable to explain why work is not happening, where *"that
one is on Ask, switch it if you want me to run it"* is the useful answer.

The gate is applied in `archon goals` and again inside `prompt`/`stop`, so
there is no command that quietly routes around it.

## Auto-management

The user switches an agent on and gives it a goal. Archon works toward it, and
when it is met **switches the agent off and leaves a note, in one step**. A
toggle left on beside a note would read as work still running.

- Turning an agent on **asks for the goal there and then** — without one there
  is nothing to call finished, so a blank brief is refused rather than stored.
- The **permission gate still decides**. The toggle is the user's intent; the
  permission is their authority, and the narrower wins.
- The note must carry the fact that settles it — *"CI green on main since
  14:02; the flake was a missing await"* — not "completed successfully". The
  skill says so explicitly, and also says not to mark a goal done because an
  agent claimed it was.

Kept in its own table (`archon_managed`), not columns on `chats`: this is
Archon's brief *about* an agent rather than something the agent has, and it is
deleted with the chat.

## Reaching other hosts

Archon runs on one host but manages agents on all of them, and **has no
credentials for the others** — those are the user's and live in the app, which
already holds a connection to each host it can see.

So the app is the route:

```
Archon (host A) → host A's daemon → a live app → host B
```

- A relayed call is **offered to every connected app; the first to answer
  wins**. Apps reach different sets of hosts, so the app that can do the job is
  the one that replies — no routing table to keep correct.
- **No app connected is an answer, not an error.** The user's app being closed
  at 3am is normal. Unanswered calls time out for the same reason, and a second
  app replying after the first is ignored.
- A relay subscriber **never receives the token stream** — only the calls meant
  for it, the same discipline as the digest subscription.

## Visibility

**Every command Archon runs is written down and shown in its tab** — what ran,
on which agent, whether it worked.

- Recorded **by the command runner, not inside each command**, so acting
  without it being visible is not something Archon can choose.
- **Refusals are logged too.** What it was stopped from doing matters as much
  as what it did.
- **Reading and listing are left out.** Archon runs those on every wake;
  logging them would bury the real actions under its own housekeeping.
- The app reads the log **from the daemon, not from Archon** — the point of a
  log is that it can be checked without asking the thing being checked.
- Bounded, because it grows with every wake forever otherwise. A failed log
  write never fails the command that already happened.

## Waking

Four triggers: a chat message, a due schedule entry, a carried-over Automate
job, and a proactive tick every 15–30 minutes.

Two behaviours worth naming:

- **A missed repeat rolls forward in whole periods.** A daemon asleep for an
  hour fires a five-minute timer *once* on waking, not twelve times.
- **A proactive tick decides from records before touching a host.** ADSM stops
  idle workers after 15 minutes, and a tick on that same cadence that
  reconnected regardless would keep resurrecting exactly the workers the reaper
  had just stopped. A tick that finds nothing pending sleeps without opening a
  bridge.

## Voice

Deepgram, both directions — transcription in, spoken replies out. It handles
**speech only**; the reply comes from Archon's agent session, so nothing in the
voice path talks to a model.

- Returns **audio as bytes rather than playing it**, keeping playback a
  separate decision and the class testable without a device.
- Settings are **resolved per call**, so a key added in settings takes effect
  immediately.
- Settings are **passed in rather than read from `SecureStore`** — on desktop
  that store reads files through `path_provider`, which no unit test can reach.
- A **cancelled recording never reaches Deepgram**, and a failed transcription
  cannot strand the mic in "transcribing…". Both are pinned by tests.

Capture is 16 kHz mono WAV: what Deepgram wants, and a fraction of the bytes of
anything richer, which matters on a phone connection. Playback needed a package
the repo lacked (`audioplayers`); `record` captures but cannot play.

## Shipping

Archon rides the same upload as ADSM, with a test asserting **every module is
listed in the app's assets** — one left out reaches no host, and the failure
would look like Archon simply not working.

Anything that changes what a host runs needs the **ADSM version bumped on both
sides**, or already-provisioned hosts never receive it. That mistake shipped
once already (`chats.fork` was unreachable on every existing host) and there is
now a test reading `VERSION` out of `protocol.py` and asserting the app agrees.

---

## Open

Not built, in the order that matters for Archon actually working:

1. **The app side of the relay.** `archon remote *` always answers `no_app`
   because nothing in the app subscribes as a route. Until this exists Archon
   manages one host.
2. **Deploying the skill on placement.** The skill is written and shipped but
   nothing installs it on Archon's host, so Archon currently behaves like a
   plain agent.
3. **The wake loop.** Triggers and the schedule exist; nothing runs Archon on
   them, so it only acts when spoken to.
4. **Voice controls in the composer.** `ArchonVoice` works and is tested, but
   no UI calls it.
5. **Absorbing the Automate jobs.** The editor moved under `/archon/schedule`;
   Archon does not run those jobs yet.

## Deliberately not done

- **Merging context across hosts.** The design rules it out unless the work is
  genuinely shared, and how "same repo" is detected is still an open question
  in the design itself.
- **Archon executing anything.** Enforced by not giving it the means: its tools
  are a directory, a prompt command and a scheduler.
