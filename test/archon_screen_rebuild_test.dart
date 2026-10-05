// Archon's placement is resolved by an async provider, and ArchonScreen swaps
// the whole ChatScreen for a spinner whenever that provider is loading. So
// anything that makes it recompute tears the chat down and rebuilds it — the
// visible symptom is the Archon screen flickering while agents stream.
import 'package:agentplantation/app/providers.dart';
import 'package:agentplantation/data/local/app_database.dart';
import 'package:agentplantation/data/models/host.dart';
import 'package:agentplantation/features/archon/archon_screen.dart';
import 'package:agentplantation/services/archon_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _host = Host(
  id: 'host-1',
  alias: 'MiniPC',
  hostname: 'localhost',
  username: 'jafar',
  createdAt: DateTime.utc(2026),
);

class _CountingArchonService extends ArchonService {
  _CountingArchonService(super.db);

  int lookups = 0;

  @override
  Future<Host?> currentHost() async {
    lookups++;
    return _host;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late _CountingArchonService service;
  late ProviderContainer container;

  setUp(() {
    service = _CountingArchonService(
      AppDatabase(overridePath: inMemoryDatabasePath),
    );
    container = ProviderContainer(
      overrides: [archonServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
  });

  test('a catalog epoch bump does not re-resolve Archon placement', () async {
    // Keep a listener alive so autoDispose does not muddy the count.
    container.listen(archonHostProvider, (_, _) {});
    await container.read(archonHostProvider.future);
    expect(service.lookups, 1);

    // HostLiveSync bumps this every 400ms, and a streaming chat every 3s.
    // Where Archon runs cannot change because an agent emitted a token.
    for (var i = 0; i < 5; i++) {
      container.read(agentsCatalogEpochProvider.notifier).state++;
      await pumpEventQueue();
    }

    expect(
      service.lookups,
      1,
      reason: 'placement is independent of catalog churn',
    );
  });

  test('a catalog epoch bump never drops the screen back to loading', () async {
    container.listen(archonHostProvider, (_, _) {});
    await container.read(archonHostProvider.future);

    final sawLoading = <bool>[];
    container.listen(archonHostProvider, (_, next) {
      sawLoading.add(next.isLoading);
    });

    container.read(agentsCatalogEpochProvider.notifier).state++;
    await pumpEventQueue();

    expect(
      sawLoading,
      isNot(contains(true)),
      reason: 'a spinner here replaces the whole chat — that is the flicker',
    );
  });

  test('placement changes still refresh when Archon is actually moved', () async {
    container.listen(archonHostProvider, (_, _) {});
    await container.read(archonHostProvider.future);
    expect(service.lookups, 1);

    container.invalidate(archonHostProvider);
    await container.read(archonHostProvider.future);

    expect(service.lookups, 2);
  });
}
