import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/agents/agents_screen.dart';
import '../features/agents/chat_screen.dart';
import '../features/connect/connect_screen.dart';
import '../features/hosts/host_edit_screen.dart';
import '../features/hosts/hosts_screen.dart';
import '../features/repos/repo_edit_screen.dart';
import '../features/repos/repos_screen.dart';
import '../features/settings/mcp_edit_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/terminal/terminal_hosts_screen.dart';
import '../features/terminal/terminal_session_screen.dart';
import 'shell_scaffold.dart';

final _rootKey = GlobalKey<NavigatorState>();

final goRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/agents',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            ShellScaffold(navigationShell: navigationShell),
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
                path: '/terminal',
                builder: (context, state) => const TerminalHostsScreen(),
                routes: [
                  GoRoute(
                    path: 'session/:hostId',
                    builder: (context, state) => TerminalSessionScreen(
                      hostId: state.pathParameters['hostId']!,
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
                    path: ':hostId/repos',
                    builder: (context, state) =>
                        ReposScreen(hostId: state.pathParameters['hostId']!),
                    routes: [
                      GoRoute(
                        path: 'new',
                        builder: (context, state) =>
                            RepoEditScreen(hostId: state.pathParameters['hostId']!),
                      ),
                      GoRoute(
                        path: 'edit/:repoId',
                        builder: (context, state) => RepoEditScreen(
                          hostId: state.pathParameters['hostId']!,
                          repoId: state.pathParameters['repoId'],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/connect',
                builder: (context, state) => const ConnectScreen(),
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
    ],
  );
});
