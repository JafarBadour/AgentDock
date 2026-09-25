/// What a file name looks like it holds.
///
/// Used in two places: the project file browser, to decide whether tapping an
/// entry opens a viewer or a download, and the chat transcript, to decide what
/// to offer when the agent mentions a path.
enum FileKind {
  pdf,
  markdown,
  text,
  image,

  /// Anything we cannot render — offer a download instead.
  binary,
}

extension FileKindX on FileKind {
  /// True when the app can show this file itself.
  bool get isViewable => this != FileKind.binary;
}

const Set<String> _markdownExts = {
  'md',
  'markdown',
  'mdx',
  'mdown',
  'mkd',
  'mkdn',
};

const Set<String> _imageExts = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
};

/// Extensions we render as plain (monospace) text.
const Set<String> _textExts = {
  // Code
  'dart', 'py', 'pyi', 'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx', 'java', 'kt',
  'kts', 'swift', 'm', 'mm', 'c', 'h', 'cc', 'cpp', 'cxx', 'hpp', 'hh', 'cs',
  'go', 'rs', 'rb', 'php', 'pl', 'pm', 'sh', 'bash', 'zsh', 'fish', 'ps1',
  'sql', 'r', 'scala', 'lua', 'vim', 'ex', 'exs', 'erl', 'hs', 'clj', 'cljs',
  'groovy', 'gradle', 'tf', 'hcl', 'proto', 'graphql', 'gql', 'prisma', 'sol',
  'zig', 'nim', 'jl', 'f90', 'pas', 'vb', 'awk', 'asm', 's', 'vue', 'svelte',
  'astro', 'ipynb', 'applescript',
  // Markup / data / config
  'json', 'jsonl', 'json5', 'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf',
  'properties', 'env', 'xml', 'plist', 'html', 'htm', 'css', 'scss', 'sass',
  'less', 'svg', 'csv', 'tsv', 'rst', 'tex', 'bib', 'po', 'srt', 'vtt',
  'desktop', 'service', 'lock', 'mk', 'cmake', 'bat', 'cmd', 'gitignore',
  'gitattributes', 'gitmodules', 'dockerignore', 'editorconfig', 'npmrc',
  'nvmrc', 'babelrc', 'eslintrc', 'prettierrc', 'terraformrc',
  // Output
  'txt', 'text', 'log', 'out', 'err', 'diff', 'patch', 'trace',
};

/// Extensionless file names that are still plain text.
const Set<String> _textNames = {
  'dockerfile',
  'makefile',
  'gnumakefile',
  'rakefile',
  'gemfile',
  'brewfile',
  'justfile',
  'procfile',
  'vagrantfile',
  'jenkinsfile',
  'cmakelists',
  'license',
  'licence',
  'readme',
  'changelog',
  'notice',
  'authors',
  'contributors',
  'codeowners',
  'todo',
};

/// Binary-ish extensions that still read as a file mention in prose, so a
/// mentioned `report.xlsx` or `build.apk` can be downloaded from the chat.
const Set<String> _binaryExts = {
  'zip', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'zst', '7z', 'rar',
  'apk', 'aab', 'ipa', 'jar', 'war', 'exe', 'dll', 'so', 'dylib', 'a', 'o',
  'bin', 'iso', 'img', 'dmg', 'deb', 'rpm', 'msi', 'whl', 'egg',
  'mp3', 'mp4', 'mov', 'avi', 'mkv', 'wav', 'flac', 'ogg', 'webm', 'm4a',
  'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp', 'epub',
  'ttf', 'otf', 'woff', 'woff2', 'eot', 'ico', 'icns', 'tiff', 'tif', 'heic',
  'psd', 'sketch', 'fig',
  'db', 'sqlite', 'sqlite3', 'realm', 'mdb',
  'pkl', 'pt', 'pth', 'onnx', 'safetensors', 'ckpt', 'npz', 'npy', 'parquet',
  'keystore', 'jks', 'p12', 'pfx', 'pem', 'crt', 'cer', 'der', 'key',
  'class', 'pyc', 'wasm', 'dSYM',
};

/// Classify [name] (a file name or a path) by extension.
FileKind fileKindFor(String name) {
  final base = _basename(name);
  if (base.isEmpty) return FileKind.binary;
  final ext = fileExtension(base);
  if (ext.isEmpty) {
    return _textNames.contains(base.toLowerCase())
        ? FileKind.text
        : FileKind.binary;
  }
  if (ext == 'pdf') return FileKind.pdf;
  if (_markdownExts.contains(ext)) return FileKind.markdown;
  if (_imageExts.contains(ext)) return FileKind.image;
  if (_textExts.contains(ext)) return FileKind.text;
  // `README.old`, `notes.1` — the stem alone says text.
  final stem = base.substring(0, base.length - ext.length - 1).toLowerCase();
  if (_textNames.contains(stem)) return FileKind.text;
  return FileKind.binary;
}

/// Lowercase extension without the dot, or `''` when there is none.
///
/// Dotfiles (`.gitignore`) are treated as all-extension, since that is the
/// part that says what they hold.
String fileExtension(String name) {
  final base = _basename(name);
  final dot = base.lastIndexOf('.');
  if (dot < 0 || dot == base.length - 1) return '';
  if (dot == 0) return base.substring(1).toLowerCase();
  return base.substring(dot + 1).toLowerCase();
}

String _basename(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final trimmed = normalized.endsWith('/') && normalized.length > 1
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final i = trimmed.lastIndexOf('/');
  return i < 0 ? trimmed : trimmed.substring(i + 1);
}

/// Every extension we recognise, whether or not we can render it.
bool _isKnownExtension(String ext) =>
    ext == 'pdf' ||
    _markdownExts.contains(ext) ||
    _imageExts.contains(ext) ||
    _textExts.contains(ext) ||
    _binaryExts.contains(ext);

/// A file path the agent mentioned, plus where in the text it came from.
class FileMention {
  const FileMention({required this.path, this.line});

  /// The path as written, cleaned of decoration and line suffixes.
  final String path;

  /// Line number from a `path:42` / `path#L42` suffix, when present.
  final int? line;

  String get name => _basename(path);

  FileKind get kind => fileKindFor(path);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FileMention && other.path == path && other.line == line;

  @override
  int get hashCode => Object.hash(path, line);

  @override
  String toString() => line == null ? path : '$path:$line';
}

const Map<String, String> _wrapPairs = {
  '(': ')',
  '[': ']',
  '{': '}',
  '<': '>',
  '"': '"',
  "'": "'",
};

final _lineSuffix = RegExp(r':(\d+)(?::\d+)?$');
final _hashLineSuffix = RegExp(r'#L(\d+)(?:-L?\d+)?$', caseSensitive: false);

/// Parse [raw] as a file reference, or return null when it is not one.
///
/// Deliberately strict: the chat turns these into tappable chips, and a false
/// positive on every `--flag` or `v1.2` would be worse than missing a path.
/// A token qualifies when its final segment carries a known extension, or is a
/// known extensionless name like `Dockerfile`.
FileMention? parseFileMention(String raw) {
  var s = raw.trim();
  if (s.isEmpty || s.length > 512) return null;

  // Decoration the agent wrapped it in.
  s = s.replaceAll('`', '').trim();
  while (s.length > 1 && _wrapPairs.containsKey(s[0])) {
    final close = _wrapPairs[s[0]]!;
    if (!s.endsWith(close)) break;
    s = s.substring(1, s.length - 1).trim();
  }
  s = s.replaceAll(RegExp(r'^\*+|\*+$'), '').trim();

  // Trailing prose punctuation.
  while (s.isNotEmpty && ',.;!?)]}"\''.contains(s[s.length - 1])) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty) return null;

  int? line;
  final hash = _hashLineSuffix.firstMatch(s);
  if (hash != null) {
    line = int.tryParse(hash.group(1)!);
    s = s.substring(0, hash.start);
  } else {
    final colon = _lineSuffix.firstMatch(s);
    if (colon != null) {
      line = int.tryParse(colon.group(1)!);
      s = s.substring(0, colon.start);
    }
  }
  if (s.isEmpty) return null;

  // Not a path: URLs, shell fragments, globs, multi-word text.
  if (s.contains('://')) return null;
  if (RegExp(r'\s').hasMatch(s)) return null;
  if (s.contains('*') || s.contains('?') || s.contains('|')) return null;
  if (s.startsWith('-') || s.startsWith('@') || s.startsWith('\$')) return null;
  if (s.endsWith('/')) return null;
  // `user@host:/path`, `key=value`, `Class::method`.
  if (s.contains('=') || s.contains('::')) return null;

  if (s.startsWith('./')) s = s.substring(2);
  if (s.isEmpty) return null;

  final base = _basename(s);
  if (base.isEmpty || base == '.' || base == '..') return null;

  final ext = fileExtension(base);
  final known = ext.isEmpty
      ? _textNames.contains(base.toLowerCase())
      : _isKnownExtension(ext) ||
          _textNames.contains(
            base.substring(0, base.length - ext.length - 1).toLowerCase(),
          );
  if (!known) return null;

  return FileMention(path: s, line: line);
}
