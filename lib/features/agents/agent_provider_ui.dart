import 'package:flutter/material.dart';

import '../../data/models/agent_provider.dart';

/// Icon used wherever the agent list / picker shows a provider.
IconData providerIcon(AgentProvider provider) => switch (provider) {
      AgentProvider.cursor => Icons.auto_awesome,
      AgentProvider.claude => Icons.psychology_alt_outlined,
      AgentProvider.codex => Icons.code_rounded,
    };

/// Icon for the compact segmented picker in the new-agent dialog.
IconData providerPickerIcon(AgentProvider provider) => switch (provider) {
      AgentProvider.cursor => Icons.terminal,
      AgentProvider.claude => Icons.smart_toy_outlined,
      AgentProvider.codex => Icons.code_rounded,
    };
