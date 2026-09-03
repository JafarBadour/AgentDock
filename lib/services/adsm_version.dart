/// ADSM protocol version this app build expects on the host.
///
/// Keep in sync with `host/adsm/protocol.py` `VERSION`. On connect, Agent Dock
/// upgrades the remote daemon when the host is older than this.
const String kRequiredAdsmVersion = '0.4.3';

/// Compare dotted versions (`1.2.3`). Returns negative / zero / positive like
/// `Comparable.compare`. Missing / empty versions sort as older than anything.
int compareAdsmVersions(String? a, String? b) {
  List<int> parts(String? v) {
    if (v == null || v.isEmpty) return const [0, 0, 0];
    final out = v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    while (out.length < 3) {
      out.add(0);
    }
    return out.take(3).toList();
  }

  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = pa[i].compareTo(pb[i]);
    if (d != 0) return d;
  }
  return 0;
}

bool adsmVersionMeets(String? have, String required) =>
    compareAdsmVersions(have, required) >= 0;

/// Whether [version] is ADSM ≥ 0.4.2 (supports `rpc.chunk` wire framing).
bool adsmSupportsWireChunks(String? version) =>
    adsmVersionMeets(version, '0.4.2');
