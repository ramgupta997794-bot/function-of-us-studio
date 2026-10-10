// =============================================================================
//  FUNCTION OF US STUDIO
//  A cinematic math-story graph video generator (YouTube Shorts / Reels style)
//  Theme: pure black + neon, 1080x1920 (9:16) canvas, story-driven animation.
//
//  Run:  flutter run   (see pubspec.yaml + permission notes at the bottom)
// =============================================================================

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:gal/gal.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:math_expressions/math_expressions.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

// ffmpeg-kit upstream (arthurhub/ffmpeg-kit) was retired in 2025. This import
// points at the actively maintained community fork. If your SDK resolves a
// different ffmpeg package, only this import + the two lines in _encodeVideo()
// need to change -- everything else is package-agnostic.
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

// -----------------------------------------------------------------------------
//  CONSTANTS
// -----------------------------------------------------------------------------
const double kTimelineSeconds = 12.0; // total story length
const int kExportFps = 60; // 60 fps MP4
const int kExportWidth = 1080; // 1080x1920 portrait
const int kExportHeight = 1920;
const double kSampleMinX = -10.0; // equation plot domain
const double kSampleMaxX = 10.0;
const int kSampleCount = 1400;

Color hexColor(String h) {
  var s = h.replaceAll('#', '').trim();
  if (s.length == 6) s = 'FF$s';
  return Color(int.parse(s, radix: 16));
}

// -----------------------------------------------------------------------------
//  PALETTE
// -----------------------------------------------------------------------------
class Palette {
  static const Color bg = Color(0xFF000000);
  static const Color grid = Color(0xFF1A1A1A);
  static const Color axis = Color(0xFF2A2A2A);
  static const Color cyan = Color(0xFF22D3EE);
  static const Color violet = Color(0xFFA855F7);
  static const Color text = Color(0xFFEDEDED);
  static const Color subText = Color(0xFF8A8A8A);
}

// -----------------------------------------------------------------------------
//  DATA MODELS
// -----------------------------------------------------------------------------
class CurveSpec {
  String label;
  String equation;
  Color color;
  bool visible;
  bool glow;

  /// Timeline fractions (0..1) at which this curve begins drawing and how long
  /// its draw-in takes. Drives the story mode.
  double appear;
  double duration;

  CurveSpec({
    required this.label,
    required this.equation,
    required this.color,
    this.visible = true,
    this.glow = true,
    this.appear = 0.0,
    this.duration = 0.3,
  });
}

/// A parsed + sampled curve handed to the painter each frame.
class CurveDraw {
  final List<Offset> points; // world-space (x, y)
  final Color color;
  final String label;
  final double appear;
  final double duration;
  final bool glow;
  const CurveDraw({
    required this.points,
    required this.color,
    required this.label,
    required this.appear,
    required this.duration,
    required this.glow,
  });
}

class CameraState {
  final Offset center; // world-space centre of the viewport
  final double halfWidth; // half of the visible world width
  const CameraState(this.center, this.halfWidth);
}

class CamKey {
  final double time; // 0..1
  final Offset center;
  final double halfW;
  const CamKey(this.time, this.center, this.halfW);
}

// -----------------------------------------------------------------------------
//  EQUATION ENGINE  (math_expressions)
// -----------------------------------------------------------------------------
class EquationEngine {
  static final ExpressionParser _parser = GrammarParser();

  /// Accepts inputs like "y=x^3", "x^3", "cbrt(x)", "sin(x)*3".
  /// Returns a math_expressions-ready expression string.
  static String normalize(String input) {
    var s = input.trim();
    final eq = s.indexOf('=');
    if (eq != -1) s = s.substring(eq + 1); // drop the "y=" / "f(x)=" prefix
    s = s.replaceAll(' ', '');
    s = s.replaceAll('\u2212', '-'); // unicode minus -> ascii
    s = _expandCbrt(s);
    return s;
  }

  /// math_expressions has no cbrt(); rewrite cbrt(u) as u / (u*u)^(1/3),
  /// which is correct for negative u too and produces NaN at u==0 (dropped
  /// harmlessly by the sampler).
  static String _expandCbrt(String s) {
    final idx = s.indexOf('cbrt(');
    if (idx == -1) return s;
    final start = idx + 5;
    var depth = 1;
    var i = start;
    for (; i < s.length; i++) {
      if (s[i] == '(') {
        depth++;
      } else if (s[i] == ')') {
        depth--;
        if (depth == 0) break;
      }
    }
    if (i >= s.length) return s; // unmatched paren, leave as-is
    final inner = s.substring(start, i);
    final replaced =
        '${s.substring(0, idx)}(($inner)/((($inner)*($inner))^(1.0/3.0)))${s.substring(i + 1)}';
    return _expandCbrt(replaced);
  }

  static Expression parse(String input) => _parser.parse(normalize(input));

  /// Samples the expression across [xMin, xMax] into world-space points.
  /// Non-finite / runaway values are emitted as NaN so the painter can break
  /// the stroke there (handles asymptotes and cbrt(0)).
  static List<Offset> sample(Expression exp, double xMin, double xMax, int n) {
    final out = <Offset>[];
    final cm = ContextModel();
    final xVar = Variable('x');
    for (var i = 0; i < n; i++) {
      final x = xMin + (xMax - xMin) * i / (n - 1);
      cm.bindVariable(xVar, Number(x));
      double y;
      try {
        y = (exp.evaluate(EvaluationType.REAL, cm) as num).toDouble();
        if (!y.isFinite || y.abs() > 1e4) y = double.nan;
      } catch (_) {
        y = double.nan;
      }
      out.add(Offset(x, y));
    }
    return out;
  }
}

// -----------------------------------------------------------------------------
//  DEFAULT STORY
// -----------------------------------------------------------------------------
List<CurveSpec> defaultCurves() => [
      CurveSpec(
        label: 'The Stranger',
        equation: 'cbrt(x)',
        color: hexColor('#5EEAD4'),
        appear: 0.00,
        duration: 0.30,
      ),
      CurveSpec(
        label: 'The Friend',
        equation: 'sin(x)*3',
        color: hexColor('#FBBF24'),
        appear: 0.33,
        duration: 0.25,
      ),
      CurveSpec(
        label: 'The Lover',
        equation: 'x',
        color: hexColor('#22D3EE'),
        appear: 0.66,
        duration: 0.20,
      ),
      CurveSpec(
        label: 'The Ex',
        equation: 'x^3',
        color: hexColor('#C084FC'),
        appear: 0.90,
        duration: 0.10,
      ),
    ];

// Camera keyframes: wide establishing shot -> slow push-in toward origin.
const List<CamKey> kCameraKeys = [
  CamKey(0.00, Offset(0, 0), 9.0),
  CamKey(0.45, Offset(0, 0), 6.5),
  CamKey(0.75, Offset(0, 0.6), 4.2),
  CamKey(1.00, Offset(0, 1.2), 3.2),
];

// -----------------------------------------------------------------------------
//  THE PAINTER  (grid, dashed reference, glowing curves, floating labels)
// -----------------------------------------------------------------------------
class GraphPainter extends CustomPainter {
  final double t; // 0..1 timeline
  final List<CurveDraw> curves;

  GraphPainter({required this.t, required this.curves});

  static final Map<String, TextPainter> _labelCache = {};

  TextPainter _labelPainter(String label) {
    return _labelCache.putIfAbsent(label, () {
      final tp = TextPainter(textDirection: TextDirection.ltr);
      tp.text = TextSpan(
        text: label,
        style: GoogleFonts.spaceGrotesk(
          fontSize: 26,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: Colors.white,
        ),
      );
      tp.layout();
      return tp;
    });
  }

  CameraState _camAt(double t) {
    final keys = kCameraKeys;
    if (t <= keys.first.time) {
      return CameraState(keys.first.center, keys.first.halfW);
    }
    if (t >= keys.last.time) {
      return CameraState(keys.last.center, keys.last.halfW);
    }
    for (var i = 0; i < keys.length - 1; i++) {
      final a = keys[i];
      final b = keys[i + 1];
      if (t >= a.time && t <= b.time) {
        final f = (t - a.time) / (b.time - a.time);
        final e = Curves.easeInOut.transform(f);
        return CameraState(
          Offset.lerp(a.center, b.center, e)!,
          a.halfW + (b.halfW - a.halfW) * e,
        );
      }
    }
    return CameraState(keys.last.center, keys.last.halfW);
  }

  double _niceStep(double halfW) {
    final raw = halfW / 5.0;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final norm = raw / mag;
    double step;
    if (norm < 1.5) {
      step = 1;
    } else if (norm < 3.5) {
      step = 2;
    } else if (norm < 7.5) {
      step = 5;
    } else {
      step = 10;
    }
    return step * mag;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cam = _camAt(t);
    final halfH = cam.halfWidth * size.height / size.width;

    Offset toScreen(double x, double y) => Offset(
          size.width / 2 + (x - cam.center.dx) / cam.halfWidth * (size.width / 2),
          size.height / 2 - (y - cam.center.dy) / halfH * (size.height / 2),
        );

    // Background + soft central aura.
    canvas.drawRect(Offset.zero & size, Paint()..color = Palette.bg);
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width * 0.9,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(size.width / 2, size.height / 2),
          size.width * 0.9,
          [
            hexColor('#C084FC').withOpacity(0.07),
            hexColor('#5EEAD4').withOpacity(0.03),
            Colors.transparent,
          ],
          [0.0, 0.45, 1.0],
        ),
    );

    _drawGrid(canvas, size, cam, halfH, toScreen);
    _drawReference(canvas, size, cam, halfH, toScreen);

    for (final c in curves) {
      _drawCurve(canvas, size, c, toScreen);
    }

    _drawCaption(canvas, size);
    _drawVignette(canvas, size);
  }

  void _drawGrid(Canvas canvas, Size size, CameraState cam, double halfH,
      Offset Function(double, double) toScreen) {
    final step = _niceStep(cam.halfWidth);
    final drift = step * (t * 0.6); // subtle "infinite" motion
    final left = cam.center.dx - cam.halfWidth;
    final right = cam.center.dx + cam.halfWidth;
    final bottom = cam.center.dy - halfH;
    final top = cam.center.dy + halfH;

    final minor = Paint()
      ..color = Palette.grid
      ..strokeWidth = 1.0;

    var gx = ((left - drift) / step).floor() * step + drift;
    for (; gx <= right; gx += step) {
      final p1 = toScreen(gx, bottom);
      final p2 = toScreen(gx, top);
      canvas.drawLine(p1, p2, minor);
    }
    var gy = ((bottom - drift) / step).floor() * step + drift;
    for (; gy <= top; gy += step) {
      final p1 = toScreen(left, gy);
      final p2 = toScreen(right, gy);
      canvas.drawLine(p1, p2, minor);
    }

    // Axes.
    final axis = Paint()
      ..color = Palette.axis
      ..strokeWidth = 1.4;
    if (cam.center.dx - cam.halfWidth <= 0 && cam.center.dx + cam.halfWidth >= 0) {
      canvas.drawLine(toScreen(0, bottom), toScreen(0, top), axis);
    }
    if (cam.center.dy - halfH <= 0 && cam.center.dy + halfH >= 0) {
      canvas.drawLine(toScreen(left, 0), toScreen(right, 0), axis);
    }
  }

  void _drawReference(Canvas canvas, Size size, CameraState cam, double halfH,
      Offset Function(double, double) toScreen) {
    final span = cam.halfWidth + halfH + 2;
    final p1 = toScreen(cam.center.dx - span, cam.center.dx - span);
    final p2 = toScreen(cam.center.dx + span, cam.center.dx + span);
    _dashLine(
      canvas,
      p1,
      p2,
      16,
      12,
      Paint()
        ..color = Colors.white.withOpacity(0.10)
        ..strokeWidth = 1.4,
    );
  }

  void _dashLine(Canvas canvas, Offset a, Offset b, double dash, double gap,
      Paint paint) {
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final s = a + dir * d;
      final e = a + dir * math.min(d + dash, total);
      canvas.drawLine(s, e, paint);
      d += dash + gap;
    }
  }

  void _drawCurve(Canvas canvas, Size size, CurveDraw c,
      Offset Function(double, double) toScreen) {
    final prog = ((t - c.appear) / c.duration).clamp(0.0, 1.0);
    if (prog <= 0.0) return;

    final n = c.points.length;
    final headIdx = ((n - 1) * prog).round();

    // Build the drawn-so-far path (breaking on non-finite samples).
    final path = Path();
    var started = false;
    Offset? headWorld;
    for (var i = 0; i <= headIdx; i++) {
      final w = c.points[i];
      if (w.dy.isNaN || !w.dy.isFinite) {
        started = false;
        continue;
      }
      final s = toScreen(w.dx, w.dy);
      if (!started) {
        path.moveTo(s.dx, s.dy);
        started = true;
      } else {
        path.lineTo(s.dx, s.dy);
      }
      headWorld = w;
    }

    // Neon bloom pass (additive).
    if (c.glow) {
      canvas.saveLayer(
          Offset.zero & size, Paint()..blendMode = BlendMode.plus);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = c.color.withOpacity(0.85)
          ..strokeWidth = 7
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = c.color.withOpacity(0.55)
          ..strokeWidth = 16
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 26),
      );
      canvas.restore();
    }

    // Crisp core stroke.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 2.8
        ..color = Color.lerp(c.color, Colors.white, 0.35)!,
    );

    if (headWorld == null) return;
    final hp = toScreen(headWorld.dx, headWorld.dy);

    // Trailing glow: re-highlight the last ~14% of the drawn segment.
    if (c.glow) {
      final tailStart = math.max(0, headIdx - (n * 0.05).round());
      final tail = Path();
      var ts = false;
      for (var i = tailStart; i <= headIdx; i++) {
        final w = c.points[i];
        if (w.dy.isNaN || !w.dy.isFinite) {
          ts = false;
          continue;
        }
        final s = toScreen(w.dx, w.dy);
        if (!ts) {
          tail.moveTo(s.dx, s.dy);
          ts = true;
        } else {
          tail.lineTo(s.dx, s.dy);
        }
      }
      canvas.saveLayer(Offset.zero & size, Paint()..blendMode = BlendMode.plus);
      canvas.drawPath(
        tail,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withOpacity(0.5)
          ..strokeWidth = 6
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
      );
      canvas.restore();
    }

    // Glowing head dot.
    canvas.drawCircle(
      hp,
      26,
      Paint()
        ..color = c.color.withOpacity(0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );
    canvas.drawCircle(hp, 5.5, Paint()..color = Colors.white);

    // Floating label stuck to the head.
    final tp = _labelPainter(c.label);
    final pos = hp + const Offset(18, -40);
    final rect = Rect.fromLTWH(
        pos.dx - 12, pos.dy - 7, tp.width + 24, tp.height + 14);
    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(14));
    canvas.drawRRect(rr, Paint()..color = Colors.black.withOpacity(0.55));
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = c.color.withOpacity(0.9),
    );
    tp.paint(canvas, pos);
  }

  void _drawCaption(Canvas canvas, Size size) {
    String text;
    if (t < 0.33) {
      text = 'The Stranger appears\u2026';
    } else if (t < 0.66) {
      text = 'The Friend enters\u2026';
    } else if (t < 0.90) {
      text = 'The Lover comes close\u2026';
    } else {
      text = 'The Ex diverges to infinity';
    }
    // Fade in/out around each segment boundary.
    final seg = (t * 3) % 1.0;
    final alpha = (math.sin(seg * math.pi)).clamp(0.15, 1.0);

    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: GoogleFonts.spaceGrotesk(
          fontSize: 30,
          fontWeight: FontWeight.w500,
          letterSpacing: 1.0,
          color: Palette.text.withOpacity(alpha),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width * 0.86);

    tp.paint(
      canvas,
      Offset((size.width - tp.width) / 2, size.height * 0.80),
    );
  }

  void _drawVignette(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(size.width / 2, size.height / 2),
          size.longestSide * 0.62,
          [Colors.transparent, Colors.black.withOpacity(0.55)],
          [0.6, 1.0],
        ),
    );
  }

  @override
  bool shouldRepaint(covariant GraphPainter old) =>
      old.t != t || old.curves != curves;
}

// -----------------------------------------------------------------------------
//  ROOT APP
// -----------------------------------------------------------------------------
void main() => runApp(const FunctionOfUsApp());

class FunctionOfUsApp extends StatelessWidget {
  const FunctionOfUsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Function of Us Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Palette.bg,
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: Palette.cyan,
          secondary: Palette.violet,
          surface: Palette.bg,
        ),
      ),
      home: const StudioScreen(),
    );
  }
}

// -----------------------------------------------------------------------------
//  MAIN SCREEN
// -----------------------------------------------------------------------------
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  final GlobalKey _repaintKey = GlobalKey();

  List<CurveSpec> _curves = defaultCurves();
  List<List<Offset>> _points = [];
  List<bool> _parseErrors = [];

  bool _exporting = false;
  double _exportProgress = 0.0;
  String? _lastVideoPath;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (kTimelineSeconds * 1000).round()),
    );
    _recompute();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _recompute() {
    _points = [];
    _parseErrors = [];
    for (final c in _curves) {
      try {
        final exp = EquationEngine.parse(c.equation);
        _points.add(
            EquationEngine.sample(exp, kSampleMinX, kSampleMaxX, kSampleCount));
        _parseErrors.add(false);
      } catch (_) {
        _points.add(const []);
        _parseErrors.add(true);
      }
    }
  }

  List<CurveDraw> _buildDraws() {
    final out = <CurveDraw>[];
    for (var i = 0; i < _curves.length; i++) {
      final c = _curves[i];
      if (!c.visible) continue;
      out.add(CurveDraw(
        points: _points[i],
        color: c.color,
        label: c.label,
        appear: c.appear,
        duration: c.duration,
        glow: c.glow,
      ));
    }
    return out;
  }

  Future<void> _editCurve(int index) async {
    final c = _curves[index];
    final labelCtrl = TextEditingController(text: c.label);
    final eqCtrl = TextEditingController(text: c.equation);
    var color = c.color;
    const swatches = [
      '#C084FC',
      '#5EEAD4',
      '#22D3EE',
      '#FBBF24',
      '#F472B6',
      '#4ADE80',
      '#FB7185',
    ];

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: const Color(0xFF111111),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: Text('Edit curve',
                  style: GoogleFonts.spaceGrotesk(
                      fontWeight: FontWeight.w700, color: Palette.text)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: labelCtrl,
                    style: const TextStyle(color: Palette.text),
                    decoration: const InputDecoration(
                      labelText: 'Label',
                      labelStyle: TextStyle(color: Palette.subText),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: eqCtrl,
                    style: const TextStyle(color: Palette.text),
                    decoration: const InputDecoration(
                      labelText: 'Equation (e.g. y=x^3, cbrt(x), sin(x)*3)',
                      labelStyle: TextStyle(color: Palette.subText),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    children: swatches.map((s) {
                      final col = hexColor(s);
                      final sel = col.value == color.value;
                      return GestureDetector(
                        onTap: () => setLocal(() => color = col),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: col,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: sel ? Colors.white : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel',
                      style: TextStyle(color: Palette.subText)),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Apply',
                      style: TextStyle(color: Palette.cyan)),
                ),
              ],
            );
          },
        );
      },
    );

    if (ok == true) {
      setState(() {
        _curves[index]
          ..label = labelCtrl.text.trim().isEmpty
              ? c.label
              : labelCtrl.text.trim()
          ..equation = eqCtrl.text.trim().isEmpty
              ? c.equation
              : eqCtrl.text.trim()
          ..color = color;
        _recompute();
      });
    }
    labelCtrl.dispose();
    eqCtrl.dispose();
  }

  void _toggleVisible(int i) {
    setState(() => _curves[i].visible = !_curves[i].visible);
  }

  // ---------------------------------------------------------------------------
  //  EXPORT  ->  frame capture  ->  ffmpeg encode  ->  gallery + share
  // ---------------------------------------------------------------------------
  Future<void> _export() async {
    if (_exporting) return;
    _c.stop();
    setState(() {
      _exporting = true;
      _exportProgress = 0.0;
    });

    Directory? framesDir;
    try {
      final boundary = _repaintKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final tmp = await getTemporaryDirectory();
      framesDir = Directory(
          '${tmp.path}/fof_frames_${DateTime.now().millisecondsSinceEpoch}');
      await framesDir.create(recursive: true);

      final total = (kTimelineSeconds * kExportFps).round();
      final pixelRatio = kExportWidth / boundary.size.width;

      for (var i = 0; i <= total; i++) {
        _c.value = i / total;
        await SchedulerBinding.instance.endOfFrame;
        final image = await boundary.toImage(pixelRatio: pixelRatio);
        final bytes =
            await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        final f = File(
            '${framesDir.path}/frame_${i.toString().padLeft(5, '0')}.png');
        await f.writeAsBytes(bytes!.buffer.asUint8List());
        if (i % 6 == 0) {
          setState(() => _exportProgress = i / total);
        }
      }

      final outPath =
          '${tmp.path}/function_of_us_${DateTime.now().millisecondsSinceEpoch}.mp4';
      await _encodeVideo(framesDir.path, outPath);

      // Save to gallery, then surface a share sheet.
      await Gal.putVideo(outPath);
      _lastVideoPath = outPath;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video exported and saved to gallery.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    } finally {
      if (framesDir != null && await framesDir.exists()) {
        try {
          await framesDir.delete(recursive: true);
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _exporting = false;
          _exportProgress = 0.0;
        });
        _c.forward(from: 0);
      }
    }
  }

  Future<void> _encodeVideo(String framesDir, String outPath) async {
    final cmd = '-y -framerate $kExportFps '
        '-i $framesDir/frame_%05d.png '
        '-c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p '
        '-movflags +faststart $outPath';
    final session = await FFmpegKit.execute(cmd);
    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) {
      final log = await session.getOutput();
      throw 'ffmpeg encode failed (${rc?.getValue()}). $log';
    }
  }

  Future<void> _share() async {
    final path = _lastVideoPath;
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Export a video first.')),
      );
      return;
    }
    await Share.shareXFiles(
      [XFile(path, mimeType: 'video/mp4')],
      text: 'The Function of Us \u2014 made with Function of Us Studio',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTitle(),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: AspectRatio(
                    aspectRatio: 9 / 16,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: RepaintBoundary(
                        key: _repaintKey,
                        child: AnimatedBuilder(
                          animation: _c,
                          builder: (context, _) => CustomPaint(
                            painter: GraphPainter(
                              t: _c.value,
                              curves: _buildDraws(),
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _buildDock(),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildTitle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: ShaderMask(
        shaderCallback: (rect) => const LinearGradient(
          colors: [Palette.cyan, Palette.violet],
        ).createShader(rect),
        child: Text(
          'The Function of Us',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 30,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildDock() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withOpacity(0.12)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Curve chips row.
                SizedBox(
                  height: 44,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _curves.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, i) => _curveChip(i),
                  ),
                ),
                const SizedBox(height: 12),
                // Timeline scrubber.
                Row(
                  children: [
                    Text(
                      _fmt(_c.value * kTimelineSeconds),
                      style: GoogleFonts.spaceGrotesk(
                          color: Palette.subText, fontSize: 12),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          activeTrackColor: Palette.cyan,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Palette.cyan,
                          overlayColor: Palette.cyan.withOpacity(0.15),
                          thumbShape:
                              const RoundSliderThumbShape(enabledThumbRadius: 7),
                        ),
                        child: Slider(
                          value: _c.value,
                          onChanged: _exporting
                              ? null
                              : (v) {
                                  _c.stop();
                                  _c.value = v;
                                },
                        ),
                      ),
                    ),
                    Text(
                      _fmt(kTimelineSeconds),
                      style: GoogleFonts.spaceGrotesk(
                          color: Palette.subText, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // Controls.
                Row(
                  children: [
                    _iconBtn(
                      _c.isAnimating ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      () => setState(() {
                        if (_c.isAnimating) {
                          _c.stop();
                        } else {
                          _c.forward();
                        }
                      }),
                    ),
                    const SizedBox(width: 8),
                    _iconBtn(Icons.replay_rounded, () {
                      setState(() => _c.forward(from: 0));
                    }),
                    const Spacer(),
                    if (_lastVideoPath != null)
                      _iconBtn(Icons.ios_share_rounded, _share),
                    if (_lastVideoPath != null) const SizedBox(width: 8),
                    _exportButton(),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _curveChip(int i) {
    final c = _curves[i];
    final err = _parseErrors.length > i && _parseErrors[i];
    return GestureDetector(
      onTap: () => _editCurve(i),
      onLongPress: () => _toggleVisible(i),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: c.visible
              ? c.color.withOpacity(0.14)
              : Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: c.visible
                ? c.color.withOpacity(0.8)
                : Colors.white.withOpacity(0.12),
            width: 1.2,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: c.visible ? c.color : Colors.white24,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              c.label,
              style: GoogleFonts.spaceGrotesk(
                color: c.visible ? Colors.white : Palette.subText,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            if (err) ...[
              const SizedBox(width: 6),
              const Icon(Icons.error_outline,
                  color: Color(0xFFFB7185), size: 14),
            ],
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.12)),
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  Widget _exportButton() {
    return GestureDetector(
      onTap: _exporting ? null : _export,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Palette.cyan, Palette.violet],
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Palette.violet.withOpacity(0.5),
              blurRadius: 18,
              spreadRadius: -2,
            ),
          ],
        ),
        child: Center(
          child: _exporting
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.black),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${(_exportProgress * 100).toStringAsFixed(0)}%',
                      style: GoogleFonts.spaceGrotesk(
                        color: Colors.black,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                )
              : Text(
                  'EXPORT VIRAL VIDEO',
                  style: GoogleFonts.spaceGrotesk(
                    color: Colors.black,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    letterSpacing: 0.4,
                  ),
                ),
        ),
      ),
    );
  }

  String _fmt(double seconds) {
    final s = seconds.floor();
    final d = ((seconds - s) * 10).floor();
    return '$s.${d}s';
  }
}
