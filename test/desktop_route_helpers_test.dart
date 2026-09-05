import 'package:agent_dock/app/platform_layout.dart';
import 'package:agent_dock/app/providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('desktop route helpers', () {
    test('panel roots open the right rail panel only', () {
      expect(isDesktopPanelRoot('/hosts'), isTrue);
      expect(isDesktopPanelRoot('/automate'), isTrue);
      expect(isDesktopPanelRoot('/connect'), isTrue);
      expect(isDesktopPanelRoot('/settings'), isTrue);
      expect(isDesktopPanelRoot('/hosts/new'), isFalse);
      expect(isDesktopDetailRoute('/hosts'), isFalse);
    });

    test('nested host/automate/settings routes are desktop details', () {
      expect(isDesktopDetailRoute('/hosts/new'), isTrue);
      expect(isDesktopDetailRoute('/hosts/edit/abc'), isTrue);
      expect(isDesktopDetailRoute('/hosts/terminal/abc'), isTrue);
      expect(isDesktopDetailRoute('/hosts/abc/repos'), isTrue);
      expect(isDesktopDetailRoute('/automate/new'), isTrue);
      expect(isDesktopDetailRoute('/automate/edit/1'), isTrue);
      expect(isDesktopDetailRoute('/settings/mcp/new'), isTrue);
      expect(isDesktopDetailRoute('/settings/mcp/x'), isTrue);
      expect(isDesktopDetailRoute('/agents'), isFalse);
      expect(isDesktopDetailRoute('/agents/chat/1'), isFalse);
    });

    test('terminal host id is parsed from the session path', () {
      expect(terminalHostIdFromPath('/hosts/terminal/abc'), 'abc');
      expect(terminalHostIdFromPath('/hosts/terminal/abc/extra'), 'abc');
      expect(terminalHostIdFromPath('/hosts/edit/abc'), isNull);
      expect(terminalHostIdFromPath('/agents'), isNull);
    });

    test('panel-for-path still maps sections', () {
      expect(desktopPanelForPath('/hosts/new'), DesktopRightPanel.hosts);
      expect(desktopPanelForPath('/automate/edit/1'), DesktopRightPanel.automate);
      expect(desktopPanelForPath('/agents/chat/1'), isNull);
    });
  });
}
