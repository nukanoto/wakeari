import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

import '../theme.dart';

/// 単位正方形（中心 0.5, 0.5）の Path を [size] に拡大し、[rotation] ラジアン回して描く。
class _ShapePainter extends CustomPainter {
  _ShapePainter({
    required this.morph,
    required this.progress,
    required this.rotation,
    required this.color,
  });

  final Morph morph;
  final double progress;
  final double rotation;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = morph.toPath(
      progress: progress,
      rotationPivotX: 0.5,
      rotationPivotY: 0.5,
    );
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(rotation);
    canvas.translate(-size.width / 2, -size.height / 2);
    canvas.drawPath(
      path.transform(
        Matrix4.diagonal3Values(size.width, size.height, 1).storage,
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_ShapePainter old) =>
      old.progress != progress ||
      old.rotation != rotation ||
      old.color != color;
}

/// 読み込み中に、複数の形をつないで変形し続けるインジケーター。
class MorphingLoader extends StatefulWidget {
  const MorphingLoader({super.key, this.size = 96, this.color});

  final double size;
  final Color? color;

  @override
  State<MorphingLoader> createState() => _MorphingLoaderState();
}

class _MorphingLoaderState extends State<MorphingLoader>
    with SingleTickerProviderStateMixin {
  static final _sequence = [
    MaterialShapes.softBurst,
    MaterialShapes.cookie9Sided,
    MaterialShapes.pentagon,
    MaterialShapes.clover4Leaf,
    MaterialShapes.sunny,
    MaterialShapes.oval,
  ];
  static final _morphs = [
    for (var i = 0; i < _sequence.length; i++)
      Morph(_sequence[i], _sequence[(i + 1) % _sequence.length]),
  ];
  static const _stepMillis = 900;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: _stepMillis * _morphs.length),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value * _morphs.length;
          final index = t.floor().clamp(0, _morphs.length - 1);
          return CustomPaint(
            painter: _ShapePainter(
              morph: _morphs[index],
              progress: Curves.easeInOutCubicEmphasized.transform(t - index),
              rotation: _controller.value * 2 * math.pi,
              color: color,
            ),
          );
        },
      ),
    );
  }
}

/// バルブ状態を表す大きな形。ON で変形しながら回転し、OFF では静止した形に戻る。
class ValveShape extends StatefulWidget {
  const ValveShape({
    super.key,
    required this.on,
    required this.color,
    this.size = 220,
    this.child,
  });

  final bool on;
  final Color color;
  final double size;
  final Widget? child;

  @override
  State<ValveShape> createState() => _ValveShapeState();
}

class _ValveShapeState extends State<ValveShape> with TickerProviderStateMixin {
  static final _morph = Morph(
    MaterialShapes.circle,
    MaterialShapes.cookie9Sided,
  );

  late final AnimationController _morphController = AnimationController(
    vsync: this,
    duration: Motion.medium,
    value: widget.on ? 1 : 0,
  );
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );

  @override
  void initState() {
    super.initState();
    if (widget.on) _spin.repeat();
  }

  @override
  void didUpdateWidget(ValveShape old) {
    super.didUpdateWidget(old);
    if (widget.on == old.on) return;
    if (widget.on) {
      _morphController.animateTo(1, curve: Motion.spring);
      _spin.repeat();
    } else {
      _morphController.animateTo(0, curve: Curves.easeOutCubic);
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _morphController.dispose();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: Listenable.merge([_morphController, _spin]),
              builder: (context, _) => CustomPaint(
                painter: _ShapePainter(
                  morph: _morph,
                  progress: _morphController.value,
                  rotation: _spin.value * 2 * math.pi,
                  color: widget.color,
                ),
              ),
            ),
          ),
          ?widget.child,
        ],
      ),
    );
  }
}
