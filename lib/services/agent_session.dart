import '../data/models/agent_mode.dart';
import '../data/models/agent_model.dart';
import '../data/models/prompt_image.dart';
import 'cursor_acp_service.dart';

/// Shared surface used by [ChatSessionRuntime] for either raw ACP or ADSM.
abstract class AgentSession {
  Stream<AcpUpdate> get updates;
  String? get sessionId;
  AcpTransport get transport;
  AgentSessionMode get mode;
  set mode(AgentSessionMode value);
  PermissionPolicy get permissionPolicy;
  set permissionPolicy(PermissionPolicy value);
  List<AgentModel> get availableModels;
  String? get currentModelId;
  List<String> get availableModeIds;
  AcpAgentCapabilities get capabilities;
  bool get isPromptActive;
  bool get resumedInPlace;

  Future<void> prompt(
    String text, {
    List<PromptImage> images = const [],
    String? userMessageId,
    DateTime? userCreatedAt,
  });
  Future<void> cancel();
  Future<void> setMode(AgentSessionMode next);
  Future<void> setModel(String modelId);
  void setPermissionPolicy(PermissionPolicy policy);
  void resolvePermission(Object requestId, String optionId);
  void cancelOpenPermissions();
  Future<void> ensureModelCatalog({
    required List<Map<String, dynamic>> mcpServers,
  });
  void handOffPrompt();
  Future<void> close();
}
