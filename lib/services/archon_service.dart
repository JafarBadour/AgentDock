import '../data/local/app_database.dart';
import '../data/models/agent_provider.dart';
import '../data/models/archon_chat.dart';
import '../data/models/chat.dart';
import '../data/models/host.dart';
import '../data/models/repo.dart';
import 'agent_runtime_host.dart';

/// Where Archon lives, and moving it.
///
/// Archon is one reserved chat in a folder of its own on whichever host the
/// user picks. Only one is active at a time, so moving hosts repoints that
/// single row rather than making a second Archon.
class ArchonService {
  ArchonService(this._db);

  final AppDatabase _db;

  /// Repo row id for Archon's workspace on [hostId] — derived, so the same
  /// host always resolves to the same row instead of accumulating duplicates.
  static String repoIdFor(String hostId) => 'archon-workspace-$hostId';

  /// Archon's working directory on the host.
  ///
  /// Its own folder rather than one of the user's repos: Archon directs agents
  /// and never executes anything itself, so it has no reason to sit inside
  /// code it might be asked about but must not touch. `$HOME` is left for the
  /// remote shell to expand — this path is used on the host, not here.
  static const workspacePath = r'$HOME/.agentdock/archon/workspace';

  static const workspaceName = 'Archon';

  /// The Archon chat, or null when Archon has not been placed on a host yet.
  Future<Chat?> current() => _db.getChat(kArchonChatId);

  /// The host Archon currently runs on, if any.
  Future<Host?> currentHost() async {
    final chat = await current();
    if (chat == null) return null;
    final repo = await _db.getRepo(chat.repoId);
    if (repo == null) return null;
    return _db.getHost(repo.hostId);
  }

  /// Put Archon on [host], creating its workspace row if needed.
  ///
  /// Returns the Archon chat. Called again with the same host this is a
  /// no-op; called with a different one it moves, keeping the transcript —
  /// the conversation with Archon is the user's, not the host's.
  Future<Chat> placeOn(Host host) async {
    final repo = Repo(
      id: repoIdFor(host.id),
      hostId: host.id,
      name: workspaceName,
      remotePath: workspacePath,
      createdAt: DateTime.now(),
    );
    await _db.upsertRepo(repo);

    final now = DateTime.now();
    final existing = await current();
    final chat = existing == null
        ? Chat(
            id: kArchonChatId,
            repoId: repo.id,
            title: 'Archon',
            provider: AgentProvider.claude,
            tmuxSession: AgentRuntimeHost.sessionNameForChat(kArchonChatId),
            status: ChatStatus.idle,
            // Nothing Archon says is unread the moment it is created.
            lastReadAt: now,
            titleUpdatedAt: now,
            createdAt: now,
            updatedAt: now,
          )
        : existing.movedTo(repo.id, at: now);
    await _db.upsertChat(chat);
    return chat;
  }

  /// True when Archon already runs on [host].
  Future<bool> isOn(Host host) async {
    final chat = await current();
    return chat != null && chat.repoId == repoIdFor(host.id);
  }
}

extension on Chat {
  /// The same Archon, pointed at another host's workspace.
  ///
  /// The ACP session id is dropped deliberately: a session belongs to the host
  /// that minted it, and carrying it across would have Archon resume against
  /// something that does not exist there.
  Chat movedTo(String newRepoId, {required DateTime at}) => Chat(
    id: id,
    repoId: newRepoId,
    title: title,
    provider: provider,
    tmuxSession: tmuxSession,
    journalOffset: 0,
    modelId: modelId,
    lastReadAt: lastReadAt,
    status: ChatStatus.idle,
    sortOrder: sortOrder,
    titleUpdatedAt: titleUpdatedAt,
    createdAt: createdAt,
    updatedAt: at,
  );
}
