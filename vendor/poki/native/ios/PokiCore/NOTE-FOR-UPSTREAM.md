# Note for Joseph's agent: the phone-side MCP (PokiCore look/do) and how it could unify with Poki's MCP

Written Nov 7 2026, 1:30 am ET, after three rounds of owner tests on an iPhone 17 Pro (iOS 27.3 beta,
Mail, X, JD, WeChat). Zhehan is away and cannot test further builds; everything here is on the
branches so you can pick it up.

## What this is

`native/ios/PokiCore` is a Swift package that turns an on-phone XCTest runner (a Poki-branded
WebDriverAgent 16.15.3, `native/ios-runner`) into two MCP tools, served by the Poki iOS app itself over a
relay (Cloudflare Workers, `deploy/cf-relay`; the relay stores nothing and only forwards):

- `look` reads the screen: the app in front, numbered interactive elements (from the accessibility
  tree, XML), and a screenshot whose pixels are screen points.
- `do` runs a batch of actions (tap by number, text or point; type; swipe; scroll_to; button; launch;
  wait_until) and then reads the screen again, listing only what changed and a `screen_changed` line.

No model runs on the phone. The calling agent decides what happened from the elements, the picture and
the facts in the answer; PokiCore never returns a verdict. Sensitive actions (pay, delete, send, a
password field) are held for the owner's approval in a Live Activity.

Full behaviour: `docs/ios-core.md` (this repo root). Things proven only on the simulator:
`native/ios/PokiCore/UNVERIFIED.md`.

## Where the branches stand

In this repo everything iOS is on `dev/ios-standalone` (this package, the app, the runner, the
launcher and the relay); the overview for that branch is `docs/NOTE-FOR-JOSEPHS-AGENT.md`. The Node
MCP side (the look/do profile `src/cua.mjs` with a WDA backend `src/cua-wda.mjs`, and the read and
action fixes) is on `dev/mcp-agent-tools`. Both were developed on Zhehan's fork
(ZhehanZhang/poki-remote) under `dev/ios-core`, `dev/ios-app`, `dev/wda-runner`, `dev/cf-relay` and
`dev/cua-agent`. CI for this package is `.github/workflows/ios-core.yml` (manual here): unit tests on
Linux, and a simulator check on a macOS runner that drives Settings and the keyboard through the real
runner.

## What the owner's tests found, and what this round fixed (MCP side)

Round 3 (JD and WeChat, Nov 7 12:21 to 12:45 am ET) was the first real multi-app run. Fixed in
this round, each with a unit test:

1. The owner's own clipboard was pasted into JD's search box: iOS's "Allow Paste" prompt was still up
   when PokiCore put the owner's clipboard back. Now the clipboard is verified after the write and put
   back only once the field shows the text (or after 45 s).
2. Tree reads came back as the Home screen while an app was in front: a banner sat on WDA's "active
   app detection point" (top left). The point is now the middle of the screen.
3. Every failed `look` in WeChat opened a new session that queued behind the slow read before it. A
   read that times out now keeps the session; only an action that times out ends it (so nothing
   queued runs late).
4. A three-action `do` was answered "unknown" when the relay reset mid-call. The call now runs to the
   end and its answer is delivered in front of the next call's answer.
5. The tree and the picture could be from different moments. The picture is retaken when the tree
   came over 0.6 s later.
6. A tap on a full-screen container went to its centre silently; the answer now says so. A new
   screen says its numbers start from 1 again.

Added after that (Nov 7, 1:50 to 2:30 am ET, CI green, not yet on a phone), from the owner's rule
that no answer may halt the agent and from the first Poki Gym runs (`native/ios-gym`):

7. An answer that carries a read is never `isError`; the `error:` line says what went wrong. A busy
   runner answers `not_sent` with the picture (the screenshot is served apart from the queue); a
   starting runner says to call again; a refused runner says to call again in 10 s.
8. A hand-off channel to the owner for steps the model will not do itself: `{handoff: {kind, text}}`
   raises `CoreEvent.handoffRequested`, input is held until `PokiCore.handoffDone(id:)` (the app's
   "Your turn" Done) or `{handoff: false}`, every answer carries a `handoff:` line, and
   `{wait_until: {handoff_done: true}}` waits for it.
9. Tree reads need no WDA session; after a timed-out read the next asks for half the snapshot depth
   (min 12) and says so; `screen: moving` when the picture changed around a late tree.
10. `clear: true` is checked, typing waits up to 2 s for focus, `{back: true}`, an element listed
    twice is listed once, a tap on a container names its buttons, and a fresh launch survives an app
    that takes over 4 s to end.

11. A wedged runner (an app whose main loop hangs holds WDA's whole queue while `/status` still
    answers) is restarted by PokiCore on its own after a 15 s stall, and the next call says why; a
    tree read that times out is read again at half depth within the same call; a WKWebView with
    none of its page in the tree is listed as collapsed with the picture's text; `scroll_to` says
    how far it got when its time runs out.
12. After a timed-out read the child cap (`snapshotMaxChildren`) is lowered before the depth; a
    `look` with no picture in 6 s falls back to the host's screenshot; `scroll_to` searches by element.
13. Focus and a field's value are read from the tree (no `GET /element/active`, which waits on the
    app); `scroll_to` gets 12 s and reads after every swipe; the screenshot is retaken when the tree
    came late.
14. Typing waits for a busy runner or sends nothing (never `unknown`); a `do` never runs past its
    backstop; `wait_until: settled` starts from the fresh read before it; a read never waits on a
    session open; an explicit note when neither the runner nor the host gives a picture.
15. `scroll_to` declares the end only after two unmoved swipes to a free runner (a 300-row gym list
    gave a false end at row 180), uses its remaining time for the read after each swipe, and the
    read after it lists the found element, and it reads a swipe's result before swiping again (a
    250th-row miss); a cut listing counts what it left out by type.
16. Scrolls drag to rest (with a drag back after an overshoot); a tap on a partly hidden element goes
    to its visible part; a replaced field gets a new number; a note when focus moved; a sheet hint;
    a refused launch is one plain line.
17. A launch reads again until the app is in front; `wait_until` gets its own time; long calls
    carry a `took:` line.
18. Gestures get time to be confirmed; a note when an alert sits over a list; a stale picture is
    marked as such when no new one comes; the host's screenshot is offered beside the runner's; a
    launch works under a system alert.
19. Key `"\n"` taps the keyboard's own Go/Search/Done key when one is up; `scroll_to` drags 84 % of
    the region with a 0.2 s rest.
20. A large element (a third of the screen or more) with no parts in the tree, such as Photos'
    Library grid, is listed with a note to tap a point on the picture.
21. `scroll_to` drags 72 % of the region and checks overlap by element frames before any drag back;
    a call whose time at the MCP exceeds the tool's own by over 2 s ends with an `at the MCP:` line.
22. A Safari hint to add the scheme to a bare host; scroll drags stay clear of the bottom chrome and
    stop when a swipe changed the screen; the host screenshot beside a busy runner is capped at 6 s.

Still not done: a `collect` or `expect` field, a `recover` action, and redaction of sensitive text
(Zhehan: out of scope for now).

## How the two MCPs could unify

Poki upstream's MCP (Node, `src/`) and this one serve the same agents with different reach: yours
drives the phone from a Mac through the developer connection; this one drives it from the phone and
needs no computer. The agent-facing contract can be one:

- **Adopt look/do as the two tools**, with the answer shape PokiCore uses: `app:` line, numbered
  elements that keep their numbers across reads, `screen_changed`, per-action `sent | not_sent |
  unknown` with a time, a note line for anything odd, and the picture at one pixel per point. Agents
  trained on one would then work on both. The exact strings are in `docs/ios-core.md`, and the tests
  in `Tests/PokiCoreTests` pin them; a Node implementation can be checked against the same fixtures.
- **Keep the facts-only rule**: no verdicts, no task-specific heuristics, the model decides. That is
  what let a first-time agent do a Mail task in 9 s on the phone.
- **Phone-only pieces** stay in the app: approvals through the Live Activity, the runner's wake and
  loopback, the relay, the "Poki was in front; app brought back" rule. A Mac-side MCP has the dev
  connection and so can also offer what the phone cannot (installs, logs, a fresh runner).
- **Shared pieces** worth lifting into one module (Swift here, portable logic): element numbering and
  matching across reads, the picture-change grid, the sensitivity rules (payment and deletion words
  in 12 languages), paste with clipboard restore, and the deadline rules (per-action cap, read
  timeout, session handling around WDA's single-threaded queue).

Open questions for you: whether upstream wants the XML tree (what PokiCore reads; faster than JSON on
WDA) or keeps JSON; whether the relay should be the one entry point for both (an agent on the Mac
could also go through it); and the `back` action, which needs a per-app answer (navigation bar
button, edge swipe, Android-style key does not exist on iOS).
