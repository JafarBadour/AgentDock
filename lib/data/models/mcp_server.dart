import 'dart:convert';

enum McpTransport { stdio, http }

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
  Map<String, dynamic> toAcpConfig() {
    if (transport == McpTransport.http) {
      return {
        'type': 'http',
        'name': name,
        'url': url ?? '',
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
      };
    }
    return {
      'command': command ?? '',
      if (args.isNotEmpty) 'args': args,
      if (env.isNotEmpty) 'env': env,
    };
  }
}

class McpHostLink {
  const McpHostLink({
    required this.mcpId,
    required this.hostId,
    required this.enabled,
    required this.installStatus,
    this.installDetail,
  });

  final String mcpId;
  final String hostId;
  final bool enabled;
  final McpHostInstallStatus installStatus;
  final String? installDetail;

  Map<String, Object?> toMap() => {
        'mcp_id': mcpId,
        'host_id': hostId,
        'enabled': enabled ? 1 : 0,
        'install_status': installStatus.name,
        'install_detail': installDetail,
      };

  factory McpHostLink.fromMap(Map<String, Object?> map) => McpHostLink(
        mcpId: map['mcp_id']! as String,
        hostId: map['host_id']! as String,
        enabled: (map['enabled'] as int? ?? 0) == 1,
        installStatus: McpHostInstallStatus.fromId(
          map['install_status'] as String? ?? 'pending',
        ),
        installDetail: map['install_detail'] as String?,
      );

  McpHostLink copyWith({
    bool? enabled,
    McpHostInstallStatus? installStatus,
    String? installDetail,
    bool clearDetail = false,
  }) =>
      McpHostLink(
        mcpId: mcpId,
        hostId: hostId,
        enabled: enabled ?? this.enabled,
        installStatus: installStatus ?? this.installStatus,
        installDetail: clearDetail ? null : (installDetail ?? this.installDetail),
      );
}
