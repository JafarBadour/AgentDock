import 'package:agent_dock/data/models/agent_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real strings taken from a live `cursor-agent acp` session/new response.
void main() {
  group('parsing real model ids', () {
    test('reads every attribute from a fully specified model', () {
      final m = AgentModel.parse(
        'claude-opus-5[thinking=true,context=300k,effort=high,fast=false]',
      );
      expect(m.name, 'claude-opus-5');
      expect(m.thinking, isTrue);
      expect(m.fast, isFalse);
      expect(m.contextWindow, '300k');
      expect(m.effort, 'high');
    });

    test('treats reasoning as the same knob as effort', () {
      final m = AgentModel.parse(
        'gpt-5.6-sol[context=272k,reasoning=medium,fast=false]',
      );
      expect(m.effort, 'medium');
      expect(m.thinking, isNull, reason: 'GPT presets do not declare thinking');
      expect(m.contextWindow, '272k');
    });

    test('handles empty brackets', () {
      final m = AgentModel.fromJson({'modelId': 'default[]', 'name': 'Auto'});
      expect(m.name, 'Auto');
      expect(m.badges, isEmpty);
      expect(m.thinking, isNull);
      expect(m.fast, isNull);
    });

    test('handles an id with no brackets at all', () {
      final m = AgentModel.parse('mystery-model');
      expect(m.name, 'mystery-model');
      expect(m.badges, isEmpty);
    });

    test('display name from the agent wins over the base id', () {
      final m = AgentModel.fromJson({'modelId': 'default[]', 'name': 'Auto'});
      expect(m.name, 'Auto');
      expect(m.modelId, 'default[]');
    });

    test('round-trips the exact id, since the agent rejects anything else', () {
      const id = 'claude-opus-4-7[thinking=true,context=300k,effort=xhigh,fast=false]';
      expect(AgentModel.parse(id).modelId, id);
    });
  });

  group('badges', () {
    test('only lists attributes the model actually declares', () {
      expect(
        AgentModel.parse('grok-4.6[effort=high,fast=true]').badges,
        ['Fast', 'Effort high'],
      );
      expect(
        AgentModel.parse('claude-haiku-4-5[thinking=true]').badges,
        ['Thinking'],
      );
    });

    test('omits Fast when the model declares fast=false', () {
      final badges = AgentModel.parse(
        'gpt-5.5[context=272k,reasoning=medium,fast=false]',
      ).badges;
      expect(badges, isNot(contains('Fast')));
      expect(badges, contains('272k ctx'));
    });
  });

  group('filters', () {
    final models = [
      AgentModel.fromJson({'modelId': 'default[]', 'name': 'Auto'}),
      AgentModel.parse('grok-4.6[effort=high,fast=true]'),
      AgentModel.parse('claude-opus-5[thinking=true,context=300k,effort=high,fast=false]'),
      AgentModel.parse('claude-sonnet-4-6[thinking=true,context=200k,effort=medium]'),
      AgentModel.parse('gpt-5.5[context=272k,reasoning=medium,fast=false]'),
    ];

    List<String> apply(ModelFilter f) =>
        models.where(f.matches).map((m) => m.name).toList();

    test('thinking filter', () {
      expect(apply(ModelFilter.thinking), ['claude-opus-5', 'claude-sonnet-4-6']);
    });

    test('fast filter', () {
      expect(apply(ModelFilter.fast), ['grok-4.6']);
    });

    test('large context filter uses a numeric threshold, not string match', () {
      // 200k must be excluded while 272k and 300k are kept.
      expect(apply(ModelFilter.largeContext), ['claude-opus-5', 'gpt-5.5']);
    });
  });

  group('search', () {
    test('matches on display name and on the raw id', () {
      final m = AgentModel.parse('claude-opus-5[thinking=true,effort=high]');
      expect(m.matchesQuery('opus'), isTrue);
      expect(m.matchesQuery('OPUS'), isTrue);
      expect(m.matchesQuery('thinking'), isTrue);
      expect(m.matchesQuery('gemini'), isFalse);
    });

    test('an empty query matches everything', () {
      expect(AgentModel.parse('anything[]').matchesQuery('   '), isTrue);
    });
  });
}
