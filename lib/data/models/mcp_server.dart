import 'dart:convert';

enum McpTransport {
  stdio,
  http,
}

enum McpClientTarget {
  cursor,
  claude,
  codex;

  String get label => switch (this) {
        cursor => 'Cursor',
        claude => 'Claude',
        codex => 'Codex',
      };

  static McpClientTarget? tryParse(String raw) {
    final t = raw.trim().toLowerCase();
    for (final v in values) {
      if (v.name == t) return v;
    }
    return null;
  }
}

enum McpHostInstallStatus {
  pending,
  installing,
  installed,
  failed,
  removed;

  static McpHostInstallStatus fromId(String id) =>
      McpHostInstallStatus.values.firstWhere(
        (s) => s.name == id,
        orElse: () => McpHostInstallStatus.pending,
      );
}

/// Local MCP server definition. Deployed to selected hosts via SSH.
class McpServer {
  const McpServer({
    required this.id,
    required this.name,
    required this.transport,
    this.command,
    this.args = const [],
    this.url,
    this.env = const {},
    required this.createdAt,
  });

  final String id;
  final String name;
  final McpTransport transport;
  final String? command;
  final List<String> args;
  final String? url;
  final Map<String, String> env;
  final DateTime createdAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'transport': transport.name,
        'command': command,
        'args_json': jsonEncode(args),
        'url': url,
        'env_json': jsonEncode(env),
        'created_at': createdAt.toIso8601String(),
      };

  factory McpServer.fromMap(Map<String, Object?> map) {
    List<String> args = const [];
    final rawArgs = map['args_json'] as String?;
    if (rawArgs != null && rawArgs.isNotEmpty) {
      final decoded = jsonDecode(rawArgs);
      if (decoded is List) {
        args = decoded.map((e) => e.toString()).toList();
      }
    }
    Map<String, String> env = const {};
    final rawEnv = map['env_json'] as String?;
    if (rawEnv != null && rawEnv.isNotEmpty) {
      final decoded = jsonDecode(rawEnv);
      if (decoded is Map) {
        env = decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    }
    final transportName = map['transport'] as String? ?? 'stdio';
    return McpServer(
      id: map['id']! as String,
      name: map['name']! as String,
      transport: transportName == 'http' ? McpTransport.http : McpTransport.stdio,
      command: map['command'] as String?,
      args: args,
      url: map['url'] as String?,
      env: env,
      createdAt: DateTime.parse(map['created_at']! as String),
    );
  }

  /// Shape expected by ACP `session/new` mcpServers + ~/.cursor/mcp.json entry.
  ///
  /// For HTTP MCPs, [env] is treated as request headers (e.g. Authorization).
  Map<String, dynamic> toAcpConfig() {
    if (transport == McpTransport.http) {
      return {
        'type': 'http',
        'name': name,
        'url': url ?? '',
        if (env.isNotEmpty) 'headers': env,
      };
    }
    return {
      'type': 'stdio',
      'name': name,
      'command': command ?? '',
      'args': args,
      if (env.isNotEmpty) 'env': env,
    };
  }

  /// Entry under mcpServers[name] for ~/.cursor/mcp.json.
  Map<String, dynamic> toMcpJsonEntry() {
    if (transport == McpTransport.http) {
      return {
        'url': url ?? '',
        if (env.isNotEmpty) 'headers': env,
      };
    }
    return {
      'command': command ?? '',
      if (args.isNotEmpty) 'args': args,
      if (env.isNotEmpty) 'env': env,
    };
  }

  /// User-scope entry for Claude Code `~/.claude.json` mcpServers.
  Map<String, dynamic> toClaudeMcpJsonEntry() {
    if (transport == McpTransport.http) {
      return {
        'type': 'http',
        'url': url ?? '',
        if (env.isNotEmpty) 'headers': env,
      };
    }
    return {
      'type': 'stdio',
      'command': command ?? '',
      if (args.isNotEmpty) 'args': args,
      if (env.isNotEmpty) 'env': env,
    };
  }

  /// TOML fragment for Codex `~/.codex/config.toml` `[mcp_servers.<name>]`.
  String toCodexTomlFragment() {
    final key = _codexServerKey(name);
    final buf = StringBuffer();
    buf.writeln('[mcp_servers.$key]');
    if (transport == McpTransport.http) {
      buf.writeln('url = ${_tomlString(url ?? '')}');
      buf.writeln('enabled = true');
      if (env.isNotEmpty) {
        buf.writeln();
        buf.writeln('[mcp_servers.$key.http_headers]');
        for (final e in env.entries) {
          buf.writeln('${_tomlBareOrQuotedKey(e.key)} = ${_tomlString(e.value)}');
        }
      }
    } else {
      buf.writeln('command = ${_tomlString(command ?? '')}');
      if (args.isNotEmpty) {
        buf.writeln(
          'args = [${args.map(_tomlString).join(', ')}]',
        );
      }
      buf.writeln('enabled = true');
      if (env.isNotEmpty) {
        buf.writeln();
        buf.writeln('[mcp_servers.$key.env]');
        for (final e in env.entries) {
          buf.writeln('${_tomlBareOrQuotedKey(e.key)} = ${_tomlString(e.value)}');
        }
      }
    }
    return buf.toString().trimRight();
  }

  static String _codexServerKey(String name) {
    // Prefer bare keys; quote when the name has unusual characters.
    if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name)) return name;
    return _tomlString(name);
  }

  static String _tomlBareOrQuotedKey(String key) {
    if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(key)) return key;
    return _tomlString(key);
  }

  static String _tomlString(String value) {
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
    return '"$escaped"';
  }
}

class McpHostLink {
  const McpHostLink({
    required this.mcpId,
    required this.hostId,
    required this.enabled,
    required this.installStatus,
    this.installDetail,
    this.targets = const [],
  });

  final String mcpId;
  final String hostId;
  final bool enabled;
  final McpHostInstallStatus installStatus;
  final String? installDetail;

  /// Which client configs on the host list this MCP (cursor / claude / codex).
  final List<McpClientTarget> targets;

  String get targetsLabel =>
      targets.map((t) => t.label).join(' · ');

  Map<String, Object?> toMap() => {
        'mcp_id': mcpId,
        'host_id': hostId,
        'enabled': enabled ? 1 : 0,
        'install_status': installStatus.name,
        'install_detail': installDetail,
        'targets_json': jsonEncode(targets.map((t) => t.name).toList()),
      };

  factory McpHostLink.fromMap(Map<String, Object?> map) {
    final targets = <McpClientTarget>[];
    final raw = map['targets_json'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            final t = McpClientTarget.tryParse('$item');
            if (t != null) targets.add(t);
          }
        }
      } catch (_) {}
    }
    return McpHostLink(
      mcpId: map['mcp_id']! as String,
      hostId: map['host_id']! as String,
      enabled: (map['enabled'] as int? ?? 0) == 1,
      installStatus: McpHostInstallStatus.fromId(
        map['install_status'] as String? ?? 'pending',
      ),
      installDetail: map['install_detail'] as String?,
      targets: targets,
    );
  }

  McpHostLink copyWith({
    bool? enabled,
    McpHostInstallStatus? installStatus,
    String? installDetail,
    List<McpClientTarget>? targets,
    bool clearDetail = false,
  }) =>
      McpHostLink(
        mcpId: mcpId,
        hostId: hostId,
        enabled: enabled ?? this.enabled,
        installStatus: installStatus ?? this.installStatus,
        installDetail:
            clearDetail ? null : (installDetail ?? this.installDetail),
        targets: targets ?? this.targets,
      );
}
