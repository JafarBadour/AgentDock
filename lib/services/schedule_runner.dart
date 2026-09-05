import 'dart:async';

import '../data/local/app_database.dart';
import '../data/models/scheduled_job.dart';
import '../data/secure/safe_log.dart';
import 'agentdock_service.dart';
import 'schedule_sync_service.dart';

/// Thin phone-side schedule helper: sync/pull + host `run_now`.
///
/// Due execution runs on ADSM (`scheduler.py`), not on this timer.
class ScheduleRunner {
  ScheduleRunner({
    required AppDatabase db,
    required ScheduleSyncService sync,
    required AgentDockService dock,
    this.onJobsChanged,
  })  : _db = db,
        _sync = sync,
        _dock = dock;

  final AppDatabase _db;
  final ScheduleSyncService _sync;
  final AgentDockService _dock;
  final void Function()? onJobsChanged;

  Timer? _timer;
  bool _ticking = false;

  void start() {
    _timer?.cancel();
    // Occasional pull so UI reflects host nextRunAt / disable after runs.
    _timer = Timer.periodic(const Duration(minutes: 2), (_) {
      unawaited(tick());
    });
    unawaited(tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => stop();

  /// Ask the host ADSM to run [jobId] immediately.
  Future<void> runNow(String jobId) async {
    try {
      await _sync.runNowOnHost(jobId);
    } catch (e) {
      SafeLog.d('schedule runNow failed', e);
      rethrow;
    } finally {
      onJobsChanged?.call();
    }
  }

  /// Pull host schedule state into local SQLite.
  ///
  /// When [syncCatalogFirst] is true, agent chats are imported before schedules
  /// so cross-device Automate lists can resolve foreign keys.
  Future<void> tick({bool syncCatalogFirst = false}) async {
    if (_ticking) return;
    _ticking = true;
    try {
      // Mac may have saved locally while host upsert failed — retry push first
      // so the phone can pull a complete set.
      await _sync.pushAllLocalJobs();
      await _sync.pullAllHosts(syncCatalogFirst: syncCatalogFirst);
      onJobsChanged?.call();
    } catch (e) {
      SafeLog.d('schedule sync tick failed', e);
    } finally {
      _ticking = false;
    }
  }

  /// Local + host upsert used by Automate UI and `/schedule`.
  Future<void> saveJob(ScheduledJob job) async {
    await _db.upsertScheduledJob(job);
    // Agent record must land on the host before (or with) the schedule, or
    // other devices cannot import the job (SQLite FK needs the chat row).
    try {
      await _dock.pushChatById(job.chatId);
    } catch (e) {
      SafeLog.d('schedule save: push agent ${job.chatId} failed', e);
    }
    try {
      final hostJob = await _sync.upsertToHost(job);
      if (hostJob != null) {
        await _db.upsertScheduledJob(hostJob);
      }
    } catch (e) {
      SafeLog.d('host schedule upsert after save failed', e);
      // Keep local copy; host will get it on next successful sync attempt.
    }
    onJobsChanged?.call();
  }

  Future<void> deleteJob(String jobId) async {
    final existing = await _db.getScheduledJob(jobId);
    if (existing != null) {
      await _sync.deleteOnHost(existing);
    }
    await _db.deleteScheduledJob(jobId);
    onJobsChanged?.call();
  }
}
