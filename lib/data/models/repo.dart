class Repo {
  const Repo({
    required this.id,
    required this.hostId,
    required this.name,
    required this.remotePath,
    this.sortOrder = 0,
    required this.createdAt,
  });

  final String id;
  final String hostId;
  final String name;
  final String remotePath;
  final int sortOrder;
  final DateTime createdAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'host_id': hostId,
        'name': name,
        'remote_path': remotePath,
        'sort_order': sortOrder,
        'created_at': createdAt.toIso8601String(),
      };

  factory Repo.fromMap(Map<String, Object?> map) => Repo(
        id: map['id']! as String,
        hostId: map['host_id']! as String,
        name: map['name']! as String,
        remotePath: map['remote_path']! as String,
        sortOrder: (map['sort_order'] as int?) ?? 0,
        createdAt: DateTime.parse(map['created_at']! as String),
      );

  Repo copyWith({String? name, String? remotePath, int? sortOrder}) => Repo(
        id: id,
        hostId: hostId,
        name: name ?? this.name,
        remotePath: remotePath ?? this.remotePath,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt,
      );
}
