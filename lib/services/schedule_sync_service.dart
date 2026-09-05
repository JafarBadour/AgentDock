import '../data/local/app_database.dart';
import '../data/models/agent_provider.dart';
import '../data/models/host.dart';
import '../data/models/scheduled_job.dart';
import '../data/secure/safe_log.dart';
import '../data/secure/secure_store.dart';
import 'adsm_client.dart';
import 'agentdock_service.dart';
import 'ssh_service.dart';

/// Pushes / pulls scheduled jobs between phone SQLite and host ADSM.
class ScheduleSyncService {
  ScheduleSyncService({
    required AppDatabase db,
    required SshService ssh,
    required SecureStore secureStore,
    required AgentDockService dock,
  })  : _db = db,
        _ssh = ssh,
        _secureStore = secureStore,
        _dock = dock;

  final AppDatabase _db;
  final SshService _ssh;
  final SecureStore _secureStore;
  final AgentDockService _dock;

  Future<Host?> hostForChat(String chatId) async {
    final chat = await _db.getChat(chatId);
    if (chat == null) return null;
    final repo = await _db.getRepo(chat.repoId);
    if (repo == null) return null;
    return _db.getHost(repo.hostId);
  }

  Future<Map<String, String>> _ensureFields(String chatId) async {
    final chat = await _db.getChat(chatId);
    if (chat == null) return {};
    final repo = await _db.getRepo(chat.repoId);
    if (repo == null) return {};
    final host = await _db.getHost(repo.hostId);
    if (host == null) return {};

    String? binary;
    try {
      await _ssh.ensureAdsm(host);
      binary = switch (chat.provider) {
        AgentProvider.cursor => await _ssh.ensureCursorCli(host),
        AgentProvider.claude => await _ssh.ensureClaudeAcpBinary(host),
      };
    } catch (e) {
      SafeLog.d('schedule ensure binary failed', e);
    }

    return {
      'cwd': repo.remotePath,
      if (binary != null) 'binary': binary,
      'provider': chat.provider.name,
      if (chat.modelId != null) 'modelId': chat.modelId!,
      if (chat.acpSessionId != null) 'resumeSessionId': chat.acpSessionId!,
    };
  }

  Future<T> _withClient<T>(
    Host host,
    Future<T> Function(AdsmClient client) fn,
  ) async {
    await _ssh.ensureAdsm(host);
    final client = await AdsmClient.connect(_ssh, host);
    try {
      return await fn(client);
    } finally {
      await client.close();
    }
  }

  /// Upsert local job onto the chat's host ADSM.
  Future<ScheduledJob?> upsertToHost(ScheduledJob job) async {
    final host = await hostForChat(job.chatId);
    if (host == null) {
      SafeLog.d('schedule upsert: no host for chat ${job.chatId}');
      return null;
    }
    final fields = await _ensureFields(job.chatId);
    final payload = job.toHostJson(
      cwd: fields['cwd'],
      binary: fields['binary'],
      provider: fields['provider'],
      modelId: fields['modelId'],
      resumeSessionId: fields['resumeSessionId'],
    );
    try {
      final result = await _withClient(host, (c) {
        return c.request('schedules.upsert', {'job': payload});
      });
      final raw = result['schedule'];
      if (raw is Map<String, dynamic>) {
        return ScheduledJob.fromHostJson(raw);
      }
      if (raw is Map) {
        return ScheduledJob.fromHostJson(Map<String, dynamic>.from(raw));
      }
      return job;
    } catch (e) {
      SafeLog.d('schedules.upsert failed', e);
      rethrow;
    }
  }

  Future<void> deleteOnHost(ScheduledJob job) async {
    final host = await hostForChat(job.chatId);
    if (host == null) return;
    try {
      await _withClient(host, (c) {
        return c.request('schedules.delete', {'id': job.id});
      });
    } catch (e) {
      SafeLog.d('schedules.delete failed', e);
      // Local delete still proceeds.
    }
  }

  Future<ScheduledJob?> runNowOnHost(String jobId) async {
    final local = await _db.getScheduledJob(jobId);
    if (local == null) return null;
    final host = await hostForChat(local.chatId);
    if (host == null) {
      throw StateError('No host for schedule chat');
    }
    // Ensure host has latest job definition before forcing a run.
    await upsertToHost(local);
    final result = await _withClient(host, (c) {
      return c.request(
        'schedules.run_now',
        {'id': jobId},
        timeout: const Duration(minutes: 15),
      );
    });
    final raw = result['schedule'];
    Map<String, dynamic>? map;
    if (raw is Map<String, dynamic>) {
      map = raw;
    } else if (raw is Map) {
      map = Map<String, dynamic>.from(raw);
    }
    if (map == null) return local;
    final updated = ScheduledJob.fromHostJson(map);
    await _db.upsertScheduledJob(updated);
    return updated;
  }

  /// Pull all schedules from [host] and merge into local SQLite.
  ///
  /// Schedules reference chat ids. When [syncCatalogFirst] is true (Automate
  /// tab open), import agents first so foreign keys resolve. Otherwise we
  /// still fetch missing agent records one-by-one.
  Future<int> pullFromHost(
    Host host, {
    bool syncCatalogFirst = false,
  }) async {
    if (syncCatalogFirst) {
      try {
        await _dock.syncHostCatalog(host);
      } catch (e) {
        SafeLog.d('schedule pull: catalog sync failed for ${host.id}', e);
      }
    }
    try {
      final result = await _withClient(host, (c) {
        return c.request('schedules.list', {});
      });
      final list = result['schedules'];
      if (list is! List) return 0;
      var n = 0;
      for (final item in list) {
        if (item is! Map) continue;
        final job = ScheduledJob.fromHostJson(Map<String, dynamic>.from(item));
        if (job.chatId.isEmpty || job.id.isEmpty) continue;
        var chat = await _db.getChat(job.chatId);
        if (chat == null) {
          await _ensureLocalChat(host, job.chatId);
          chat = await _db.getChat(job.chatId);
        }
        if (chat == null) {
          // FK requires the chat row; without it we cannot store the job.
          SafeLog.d(
            'schedule pull skip ${job.id}: chat ${job.chatId} missing on '
            '${host.displayLabel}',
          );
          continue;
        }
        await _db.upsertScheduledJob(job);
        n++;
      }
      return n;
    } catch (e) {
      SafeLog.d('schedules.list failed for ${host.id}', e);
      return 0;
    }
  }

  /// Import a single agent record so a schedule FK can land.
  Future<void> _ensureLocalChat(Host host, String chatId) async {
    try {
      final record = await _dock.pullAgentRecord(host, chatId);
      if (record == null || record.repoPath.isEmpty) return;
      final repo = await _db.findOrCreateRepoByPath(
        hostId: host.id,
        remotePath: record.repoPath,
        name: record.repoName,
      );
      final sort = await _db.nextChatSortOrder(repo.id);
      await _db.upsertChat(record.toChat(repoId: repo.id, sortOrder: sort));
    } catch (e) {
      SafeLog.d('schedule ensure chat $chatId failed', e);
    }
  }

  /// Pull from every known host (best-effort).
  Future<void> pullAllHosts({bool syncCatalogFirst = false}) async {
    final hosts = await _db.listHosts();
    final hasKey = await _secureStore.hasSshPrivateKey();
    for (final host in hosts) {
      if (!hasKey && !await _secureStore.hasHostPassword(host.id)) continue;
      await pullFromHost(host, syncCatalogFirst: syncCatalogFirst);
    }
  }

  /// Re-push every local schedule to its host (covers a failed first upsert).
  Future<void> pushAllLocalJobs() async {
    final jobs = await _db.listScheduledJobs();
    for (final job in jobs) {
      try {
        final hostJob = await upsertToHost(job);
        if (hostJob != null) {
          await _db.upsertScheduledJob(hostJob);
        }
      } catch (e) {
        SafeLog.d('schedule pushAll ${job.id} failed', e);
      }
    }
  }
}
