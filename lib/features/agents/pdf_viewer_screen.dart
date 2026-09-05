import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// Full-screen viewer for a local PDF file (downloaded from a remote host).
class PdfViewerScreen extends StatelessWidget {
  const PdfViewerScreen({
    super.key,
    required this.filePath,
    required this.title,
  });

  final String filePath;
  final String title;

  static Future<void> open(
    BuildContext context, {
    required String filePath,
    required String title,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PdfViewerScreen(filePath: filePath, title: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final exists = File(filePath).existsSync();
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
      ),
      body: !exists
          ? const Center(child: Text('PDF file missing'))
          : PdfViewer.file(
              filePath,
              params: const PdfViewerParams(
                backgroundColor: Color(0xFF1C1C1F),
              ),
            ),
    );
  }
}
