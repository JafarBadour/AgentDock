class Host {
  const Host({
    required this.id,
    required this.alias,
    required this.hostname,
    required this.username,
    this.port = 22,
    this.jumpHostId,
    this.sortOrder = 0,
    required this.createdAt,
  });

  final String id;
  final String alias;
  final String hostname;
  final String username;
  final int port;

  /// Optional ProxyJump: id of another saved [Host] used as the jump server.
  final String? jumpHostId;
  final int sortOrder;
  final DateTime createdAt;

  String get displayLabel => alias.isNotEmpty ? alias : '$username@$hostname';

  String get endpointLabel => '$username@$hostname:$port';

  Map<String, Object?> toMap() => {
        'id': id,
        'alias': alias,
        'hostname': hostname,
        'username': username,
        'port': port,
        'jump_host_id': jumpHostId,
        'sort_order': sortOrder,
        'created_at': createdAt.toIso8601String(),
      };

  factory Host.fromMap(Map<String, Object?> map) => Host(
        id: map['id']! as String,
        alias: map['alias']! as String,
        hostname: map['hostname']! as String,
        username: map['username']! as String,
        port: map['port']! as int,
        jumpHostId: map['jump_host_id'] as String?,
        sortOrder: (map['sort_order'] as int?) ?? 0,
        createdAt: DateTime.parse(map['created_at']! as String),
      );

  Host copyWith({
    String? alias,
    String? hostname,
    String? username,
    int? port,
    String? jumpHostId,
    bool clearJumpHostId = false,
    int? sortOrder,
  }) =>
      Host(
        id: id,
        alias: alias ?? this.alias,
        hostname: hostname ?? this.hostname,
        username: username ?? this.username,
        port: port ?? this.port,
        jumpHostId: clearJumpHostId ? null : (jumpHostId ?? this.jumpHostId),
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt,
      );
}
