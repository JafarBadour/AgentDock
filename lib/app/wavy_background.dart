import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Slow, layered sine waves behind the whole app shell.
class WavyBackground extends StatefulWidget {
  const WavyBackground({super.key, required this.child});

  final Widget child;

  @override
  State<WavyBackground> createState() => _WavyBackgroundState();
}

class _WavyBackgroundState extends State<WavyBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 28),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return CustomPaint(
                painter: _WavyPainter(phase: _controller.value * 2 * math.pi),
                size: Size.infinite,
              );
            },
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _WavyPainter extends CustomPainter {
  _WavyPainter({required this.phase});

  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.deep,
            AppColors.mid,
            Color(0xFF1A1624),
          ],
          stops: [0.0, 0.55, 1.0],
        ).createShader(rect),
    );

    // Soft vignette so content stays readable at the edges.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.35),
          radius: 1.15,
          colors: [
            AppColors.glow.withValues(alpha: 0.22),
            Colors.transparent,
          ],
        ).createShader(rect),
    );

    _drawWave(
      canvas,
      size,
      yFactor: 0.58,
      amplitude: size.height * 0.045,
      wavelength: size.width * 0.85,
      speed: 1.0,
      color: AppColors.glow.withValues(alpha: 0.28),
    );
    _drawWave(
      canvas,
      size,
      yFactor: 0.72,
      amplitude: size.height * 0.035,
      wavelength: size.width * 1.1,
      speed: -0.65,
      color: AppColors.accentSoft.withValues(alpha: 0.10),
    );
    _drawWave(
      canvas,
      size,
      yFactor: 0.86,
      amplitude: size.height * 0.028,
      wavelength: size.width * 0.65,
      speed: 0.45,
      color: AppColors.accent.withValues(alpha: 0.07),
    );
  }

  void _drawWave(
    Canvas canvas,
    Size size, {
    required double yFactor,
    required double amplitude,
    required double wavelength,
    required double speed,
    required Color color,
  }) {
    final path = Path()..moveTo(0, size.height);
    final baseY = size.height * yFactor;
    const steps = 48;
    for (var i = 0; i <= steps; i++) {
      final x = size.width * i / steps;
      final t = x / wavelength * 2 * math.pi;
      final y = baseY + math.sin(t + phase * speed) * amplitude;
      path.lineTo(x, y);
    }
    path
      ..lineTo(size.width, size.height)
      ..close();

    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_WavyPainter oldDelegate) => oldDelegate.phase != phase;
}
