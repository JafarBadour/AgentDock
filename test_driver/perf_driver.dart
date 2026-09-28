import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Writes each run's frame-timing summary to `PERF_OUT` (default
/// build/transcript_perf.json) so runs can be compared.
Future<void> main() => integrationDriver(
      responseDataCallback: (data) async {
        final out = Platform.environment['PERF_OUT'] ??
            'build/transcript_perf.json';
        await File(out).writeAsString(
          const JsonEncoder.withIndent('  ').convert(data),
        );
      },
    );
