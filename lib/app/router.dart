import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/agents/agents_screen.dart';
import '../features/agents/chat_screen.dart';
import '../features/automations/automations_screen.dart';
import '../features/automations/schedule_edit_screen.dart';
import '../features/hosts/host_edit_screen.dart';
import '../features/hosts/hosts_screen.dart';
import '../features/settings/api_keys_screen.dart';
import '../features/settings/mcp_edit_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/terminal/terminal_session_screen.dart';
import '../features/vpn/vpn_screen.dart';
import 'desktop_shell_scaffold.dart';
import 'platform_layout.dart';
import 'shell_scaffold.dart';

final _rootKey = GlobalKey<NavigatorState>();

final goRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/agents',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          if (useDesktopShell(context)) {
            return DesktopShellScaffold(
              navigationShell: navigationShell,
              state: state,
            );
          }
          return ShellScaffold(navigationShell: navigationShell);
        },
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/agents',
                builder: (context, state) => const AgentsScreen(),
                routes: [
                  GoRoute(
                    path: 'chat/:chatId',
                    builder: (context, state) =>
                        ChatScreen(chatId: state.pathParameters['chatId']!),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/automate',
                builder: (context, state) => const AutomationsScreen(),
                routes: [
                  GoRoute(
                    path: 'new',
                    builder: (context, state) {
                      final q = state.uri.queryParameters;
                      return ScheduleEditScreen(
                        initialChatId: q['chatId'],
                        initialPrompt: q['prompt'],
                        useCompressedContext: q['useCtx'] == '1',
                      );
                    },
                  ),
                  GoRoute(
                    path: 'edit/:jobId',
                    builder: (context, state) => ScheduleEditScreen(
                      jobId: state.pathParameters['jobId'],
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/hosts',
                builder: (context, state) => const HostsScreen(),
                routes: [
                  GoRoute(
                    path: 'new',
                    builder: (context, state) => const HostEditScreen(),
                  ),
                  GoRoute(
                    path: 'edit/:hostId',
                    builder: (context, state) =>
                        HostEditScreen(hostId: state.pathParameters['hostId']),
                  ),
                  GoRoute(
                    path: 'terminal/:hostId',
                    builder: (context, state) => TerminalSessionScreen(
                      hostId: state.pathParameters['hostId']!,
                      initialDirectory: state.uri.queryParameters['cwd'],
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/vpn',
                builder: (context, state) => const VpnScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (context, state) => const SettingsScreen(),
                routes: [
                  GoRoute(
                    path: 'keys',
                    builder: (context, state) => const ApiKeysScreen(),
                    routes: [
                      GoRoute(
                        path: ':keyId',
                        builder: (context, state) {
                          final kind = ApiKeyKind.tryParse(
                            state.pathParameters['keyId'],
                          );
                          if (kind == null) {
                            return const ApiKeysScreen();
                          }
                          return ApiKeyEditScreen(kind: kind);
                        },
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'mcp/new',
                    builder: (context, state) => const McpEditScreen(),
                  ),
                  GoRoute(
                    path: 'mcp/:mcpId',
                    builder: (context, state) =>
                        McpEditScreen(mcpId: state.pathParameters['mcpId']),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      // Legacy: Connect tab became Settings (keys) + VPN (SOCKS).
      GoRoute(
        path: '/connect',
        redirect: (context, state) => '/settings',
      ),
      // Legacy deep link from older builds.
      GoRoute(
        path: '/terminal/session/:hostId',
        redirect: (context, state) {
          final id = state.pathParameters['hostId'];
          final cwd = state.uri.queryParameters['cwd'];
          final q = (cwd == null || cwd.isEmpty)
              ? ''
              : '?${Uri(queryParameters: {'cwd': cwd}).query}';
          return '/hosts/terminal/$id$q';
        },
      ),
    ],
  );
});
