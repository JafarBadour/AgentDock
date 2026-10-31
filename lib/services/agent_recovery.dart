/// Which host failures mean "this worker cannot be reached — ensure it again".
///
/// The daemon hands these back as plain JSON-RPC error text, so the app has to
/// recognise them by message. Getting the list wrong is not cosmetic: an
/// unrecognised one is rethrown straight to the UI, and the chat looks
/// disconnected until the user forces a new session by hand.
///
/// Every one of these says the same thing in different words — the worker
/// exists but has no usable transport or session — and every one is cured by
/// the same move: an `agents.ensure` restating cwd, binary, provider and the
/// session to resume. The app is holding all of those, so it can recover
/// silently.
///
/// `agent_recovery_coverage_test.dart` reads the host's Python and fails if it
/// grows an error this file has not classified, so the list cannot silently
/// fall behind again.
library;

/// Host errors that an `agents.ensure` fixes.
const Set<String> kNeedsEnsureMarkers = {
  // The daemon has no worker for this chat at all.
  'unknown chatid',
  'agents.ensure',

  // A worker whose launch fields were lost, so it cannot start the agent.
  'fifo not attached',

  // The holder never opened the read end — tmux died or never came up.
  'could not open fifo',

  // In-flight requests orphaned because the FIFO was recycled under them.
  'agent fifo recycled',

  // Resume left no usable ACP session id. This is the one that made "it
  // disconnects unless I force a new session" true: forcing a new session
  // mints an id through ensure, so this path never runs.
  'acp session not ready',

  // The Windows backend's way of saying the worker is gone.
  'agent process not running',
};

/// Host errors that are *not* a lost worker, and must not trigger a reconnect.
///
/// Listed so the coverage test can tell "classified as fine" from "nobody has
/// looked at this yet".
const Set<String> kNotATransportFailure = {
  // A real, correct refusal: the agent is mid-turn.
  'agent is already running a turn',
  // Scheduling, not transport.
  'unknown schedule id',
  'schedule is missing cwd/binary',
  // A mode the agent rejected; re-ensuring would not change the answer.
  'collaboration_mode',
  'invalid mode',

  // Real launch failures that name their own cause. Reconnecting on these
  // would hide a broken host behind a silent retry loop, so the user sees
  // the reason instead.
  'tmux start failed',
  'agent binary not found',
  'project folder not found',

  // Host-side scheduling, after its own ensure already failed.
  'worker missing after ensure',
};

/// True when [error] means the worker needs ensuring again.
bool agentNeedsReensure(Object? error) {
  if (error == null) return false;
  final text = '$error'.toLowerCase();
  for (final marker in kNeedsEnsureMarkers) {
    if (text.contains(marker)) return true;
  }
  return false;
}
