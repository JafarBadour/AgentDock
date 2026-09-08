import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// PDF viewer for a local file. Full-screen on phone; embeddable in desktop panels.
class PdfViewerScreen extends StatelessWidget {
  const PdfViewerScreen({
    super.key,
    required this.filePath,
    required this.title,
    this.embedded = false,
    this.onBack,
    this.onDownload,
  });

  final String filePath;
  final String title;
  final bool embedded;
  final VoidCallback? onBack;
  final VoidCallback? onDownload;

  static Future<void> open(
    BuildContext context, {
    required String filePath,
    required String title,
    VoidCallback? onDownload,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PdfViewerScreen(
          filePath: filePath,
          title: title,
          onDownload: onDownload,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final exists = File(filePath).existsSync();
    final viewer = !exists
        ? const Center(child: Text('PDF file missing'))
        : PdfViewer.file(
            filePath,
            params: const PdfViewerParams(
              backgroundColor: Color(0xFF1C1C1F),
            ),
          );

    final actions = <Widget>[
      if (onDownload != null)
        IconButton(
          tooltip: 'Download',
          icon: const Icon(Icons.download),
          onPressed: onDownload,
        ),
    ];

    if (embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back to files',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: onBack,
                ),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                ...actions,
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: viewer),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: actions,
      ),
      body: viewer,
    );
  }
}
