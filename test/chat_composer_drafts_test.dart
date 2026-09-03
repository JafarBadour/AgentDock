import 'package:agent_dock/app/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ChatComposerDrafts stores and clears per chat', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final drafts = container.read(chatComposerDraftsProvider.notifier);

    drafts.setDraft('chat-a', 'hello');
    expect(container.read(chatComposerDraftsProvider)['chat-a'], 'hello');

    drafts.setDraft('chat-b', 'other');
    expect(container.read(chatComposerDraftsProvider)['chat-b'], 'other');
    expect(container.read(chatComposerDraftsProvider)['chat-a'], 'hello');

    drafts.clearDraft('chat-a');
    expect(container.read(chatComposerDraftsProvider).containsKey('chat-a'), isFalse);
    expect(container.read(chatComposerDraftsProvider)['chat-b'], 'other');
  });
}
