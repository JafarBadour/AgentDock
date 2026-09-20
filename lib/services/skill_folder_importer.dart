import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/models/skill.dart';

/// Loads a Cursor/Claude skill folder (`SKILL.md` + optional supporting files).
class SkillFolderImporter {
  SkillFolderImporter._();

  static const maxFiles = 100;
  static const maxFileBytes = 1024 * 1024; // 1 MiB per file
  static const maxTotalBytes = 8 * 1024 * 1024; // 8 MiB total

  static const _skipDirNames = {
    '.git',
    '.svn',
    '.hg',
    '__pycache__',
    'node_modules',
    '.dart_tool',
    '.idea',
    '.vscode',
  };

  static const _skipFileNames = {
    '.ds_store',
    'thumbs.db',
    'desktop.ini',
  };

  /// Read one skill directory that contains `SKILL.md` at its root.
  static Future<SkillFolderImport> load(String folderPath) async {
    final root = Directory(folderPath);
    if (!await root.exists()) {
      throw StateError('Folder not found: $folderPath');
    }

    final skillMd = File(p.join(root.path, 'SKILL.md'));
    if (!await skillMd.exists()) {
      // Also accept lowercase.
      final lower = File(p.join(root.path, 'skill.md'));
      if (!await lower.exists()) {
        throw StateError(
          'No SKILL.md in ${p.basename(root.path)}. '
          'Pick the skill folder itself (the one that contains SKILL.md).',
        );
      }
      return _loadFrom(root, lower);
    }
    return _loadFrom(root, skillMd);
  }

  /// Import every immediate child directory that contains `SKILL.md`,
  /// or a single skill if [folderPath] itself has `SKILL.md`.
  static Future<List<SkillFolderImport>> loadAll(String folderPath) async {
    final root = Directory(folderPath);
    if (!await root.exists()) {
      throw StateError('Folder not found: $folderPath');
    }

    final direct = File(p.join(root.path, 'SKILL.md'));
    final directLower = File(p.join(root.path, 'skill.md'));
    if (await direct.exists() || await directLower.exists()) {
      return [await load(folderPath)];
    }

    final imports = <SkillFolderImport>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.') || _skipDirNames.contains(name)) continue;
      final md = File(p.join(entity.path, 'SKILL.md'));
      final mdLower = File(p.join(entity.path, 'skill.md'));
      if (!await md.exists() && !await mdLower.exists()) continue;
      imports.add(await load(entity.path));
    }
    if (imports.isEmpty) {
      throw StateError(
        'No skill folders found. Expected SKILL.md here, or in subfolders.',
      );
    }
    imports.sort((a, b) => a.name.compareTo(b.name));
    return imports;
  }

  static Future<SkillFolderImport> _loadFrom(
    Directory root,
    File skillMdFile,
  ) async {
    final folderName = p.basename(root.path);
    final raw = await skillMdFile.readAsString();
    final parsed = AgentSkill.parseSkillMd(raw, fallbackName: folderName);
    var name = parsed.name;
    if (!AgentSkill.isValidName(name)) {
      name = AgentSkill.slugify(folderName);
    }
    if (!AgentSkill.isValidName(name)) {
      throw StateError(
        'Invalid skill name "$name". Use lowercase letters, numbers, hyphens.',
      );
    }

    final files = <SkillBundleFile>[];
    var total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.normalize(p.relative(entity.path, from: root.path));
      if (rel == '.' || rel.startsWith('..')) continue;
      final posix = rel.replaceAll('\\', '/');
      if (posix == 'SKILL.md' || posix == 'skill.md') continue;
      final parts = posix.split('/');
      if (parts.any((seg) => seg == '.' || seg == '..')) continue;
      if (parts.any((seg) => _skipDirNames.contains(seg))) continue;
      final base = parts.last.toLowerCase();
      if (_skipFileNames.contains(base)) continue;
      if (parts.any((seg) => seg.startsWith('.') && seg != '.')) continue;

      final length = await entity.length();
      if (length > maxFileBytes) {
        throw StateError(
          'File too large ($posix, ${length}B). Max is ${maxFileBytes}B.',
        );
      }
      total += length;
      if (total > maxTotalBytes) {
        throw StateError(
          'Skill folder exceeds ${maxTotalBytes ~/ (1024 * 1024)} MiB limit.',
        );
      }
      if (files.length >= maxFiles) {
        throw StateError('Too many files (max $maxFiles).');
      }
      files.add(
        SkillBundleFile(
          relativePath: posix,
          bytes: await entity.readAsBytes(),
        ),
      );
    }
    files.sort((a, b) => a.relativePath.compareTo(b.relativePath));

    return SkillFolderImport(
      name: name,
      description: parsed.description.isEmpty
          ? 'Imported skill: $name'
          : parsed.description,
      bodyMarkdown: parsed.bodyMarkdown.isEmpty
          ? '# $name\n'
          : parsed.bodyMarkdown,
      disableModelInvocation: parsed.disableModelInvocation,
      bundleFiles: files,
      sourcePath: root.path,
    );
  }
}

class SkillFolderImport {
  const SkillFolderImport({
    required this.name,
    required this.description,
    required this.bodyMarkdown,
    required this.disableModelInvocation,
    required this.bundleFiles,
    required this.sourcePath,
  });

  final String name;
  final String description;
  final String bodyMarkdown;
  final bool disableModelInvocation;
  final List<SkillBundleFile> bundleFiles;
  final String sourcePath;

  int get fileCount => bundleFiles.length;
}
