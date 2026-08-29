enum MessageRole { user, assistant, system, tool }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.chatId,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  final String id;
  final String chatId;
  final MessageRole role;
  final String content;
  final DateTime createdAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'chat_id': chatId,
        'role': role.name,
        'content': content,
        'created_at': createdAt.toIso8601String(),
      };

  factory ChatMessage.fromMap(Map<String, Object?> map) => ChatMessage(
        id: map['id']! as String,
        chatId: map['chat_id']! as String,
        role: MessageRole.values.firstWhere(
          (r) => r.name == map['role'],
          orElse: () => MessageRole.system,
        ),
        content: map['content']! as String,
        createdAt: DateTime.parse(map['created_at']! as String),
      );
}
