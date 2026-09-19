import 'package:agent_dock/app/platform_layout.dart';
import 'package:agent_dock/app/providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('desktop route helpers', () {
    test('panel roots open the right rail panel only', () {
      expect(isDesktopPanelRoot('/hosts'), isTrue);
      expect(isDesktopPanelRoot('/automate'), isTrue);
      expect(isDesktopPanelRoot('/vpn'), isTrue);
      expect(isDesktopPanelRoot('/connect'), isFalse);
      expect(isDesktopPanelRoot('/settings'), isTrue);
      expect(isDesktopPanelRoot('/hosts/new'), isFalse);
      expect(isDesktopDetailRoute('/hosts'), isFalse);
    });

    test('nested host/automate routes are desktop details; settings stay in panel',
        () {
      expect(isDesktopDetailRoute('/hosts/new'), isTrue);
      expect(isDesktopDetailRoute('/hosts/edit/abc'), isTrue);
      expect(isDesktopDetailRoute('/hosts/terminal/abc'), isTrue);
      expect(isDesktopDetailRoute('/automate/new'), isTrue);
      expect(isDesktopDetailRoute('/automate/edit/1'), isTrue);
      expect(isDesktopDetailRoute('/settings/mcp/new'), isFalse);
      expect(isDesktopDetailRoute('/settings/mcp/x'), isFalse);
      expect(isDesktopDetailRoute('/settings/keys'), isFalse);
      expect(isDesktopDetailRoute('/settings/keys/cursor'), isFalse);
      expect(isDesktopSettingsSubroute('/settings/mcp/x'), isTrue);
      expect(isDesktopSettingsSubroute('/settings/keys'), isTrue);
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
      expect(desktopPanelForPath('/vpn'), DesktopRightPanel.vpn);
      expect(desktopPanelForPath('/connect'), DesktopRightPanel.settings);
      expect(desktopPanelForPath('/agents/chat/1'), isNull);
    });
  });
}
