/// Absolute paths on a host, POSIX or Windows (This PC).
///
/// Paths always use forward slashes. POSIX paths are rooted at `/`. Windows
/// drive paths keep their drive: `C:\Users\me` and `/C:/Users/me` both become
/// `C:/Users/me`, and a bare drive is `C:/`.
library;

final _windowsDrive = RegExp(r'^/?([A-Za-z]:)(?:[\\/]|$)');

/// Canonical absolute path: forward slashes, no trailing slash (except roots).
String normalizeRemotePath(String path) {
  var p = path.trim();
  if (p.isEmpty) return '/';
  final drive = _windowsDrive.firstMatch(p);
  if (drive != null) {
    final rest = p
        .substring(drive.end)
        .replaceAll(r'\', '/')
        .replaceAll(RegExp('/+'), '/');
    p = '${drive.group(1)!.toUpperCase()}/$rest';
    while (p.length > 3 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
  if (!p.startsWith('/')) p = '/$p';
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}

/// True for `/…` and Windows drive paths (`C:\…`, `C:/…`).
bool isAbsoluteRemotePath(String path) {
  final p = path.trim();
  return p.startsWith('/') || _windowsDrive.hasMatch(p);
}

/// True for `/` and Windows drive roots like `C:/`.
bool isRemoteRoot(String normalized) =>
    normalized == '/' || (normalized.length == 3 && normalized.endsWith(':/'));

/// True if [path] is [root] or a child of [root].
bool isUnderRemoteRoot(String root, String path) {
  final r = normalizeRemotePath(root);
  final p = normalizeRemotePath(path);
  if (r == '/') return true;
  if (r.endsWith('/')) return p.startsWith(r);
  return p == r || p.startsWith('$r/');
}

String joinRemotePath(String parent, String child) {
  final base = normalizeRemotePath(parent);
  if (base.endsWith('/')) return '$base$child';
  return '$base/$child';
}

/// Parent directory, or null at a root.
String? parentRemotePath(String path) {
  final normalized = normalizeRemotePath(path);
  if (isRemoteRoot(normalized)) return null;
  final index = normalized.lastIndexOf('/');
  if (index <= 0) return '/';
  // `C:/Users` → `C:/`, not `C:`.
  if (index == 2 && normalized[1] == ':') return normalized.substring(0, 3);
  return normalized.substring(0, index);
}

/// Last path segment, or `root` at a root.
String remoteBasename(String path) {
  final normalized = normalizeRemotePath(path);
  if (isRemoteRoot(normalized)) return 'root';
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}
