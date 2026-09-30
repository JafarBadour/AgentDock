import 'chat.dart';

/// Archon is a chat like any other, so it inherits the transcript, streaming,
/// reconnect and multi-device sync that already work — but it is the user's
/// manager, not one of the agents it manages, so it never appears in the
/// Agents list.
///
/// A reserved id rather than a schema column: only one Archon is active at a
/// time, and moving it between hosts changes which repo its row points at, not
/// which row it is.
const String kArchonChatId = 'archon';

extension ArchonChat on Chat {
  bool get isArchon => id == kArchonChatId;
}

/// [chats] without Archon — what the Agents list and its badges are about.
List<Chat> withoutArchon(Iterable<Chat> chats) => [
  for (final chat in chats)
    if (chat.id != kArchonChatId) chat,
];
