import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Carries UI-wide preferences down the tree. Reduced motion comes from the OS
/// (Windows "show animations"), so every animated widget can opt out at once.
class UiOptions extends InheritedWidget {
  const UiOptions({super.key, required this.reducedMotion, required super.child});

  final bool reducedMotion;

  static bool reducedMotionOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiOptions>()?.reducedMotion ?? false;

  @override
  bool updateShouldNotify(UiOptions oldWidget) => oldWidget.reducedMotion != reducedMotion;
}

/// Fade + rise entrance, optionally staggered behind earlier siblings.
///
/// Honours reduced motion by rendering the child immediately.
class Entrance extends StatefulWidget {
  const Entrance({
    super.key,
    required this.child,
    this.index = 0,
    this.delay,
    this.offset = 10,
  });

  final Widget child;

  /// Position in a group; multiplied by [Motion.stagger] for the delay.
  final int index;

  /// Explicit delay, overriding the [index]-derived stagger.
  final Duration? delay;

  /// Vertical travel in logical pixels.
  final double offset;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: Motion.entrance);
  late final Animation<double> _anim =
      CurvedAnimation(parent: _controller, curve: Motion.curve);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;

    if (UiOptions.reducedMotionOf(context)) {
      _controller.value = 1;
      return;
    }
    // Capped, so a page with many cards still settles promptly - see
    // Motion.staggerLimit.
    final delay = widget.delay ??
        Motion.stagger *
            (widget.index > Motion.staggerLimit
                ? Motion.staggerLimit
                : widget.index);
    if (delay == Duration.zero) {
      _controller.forward();
    } else {
      Future<void>.delayed(delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, child) {
        final v = _anim.value;
        // At rest, hand back the child untouched. Opacity composites its
        // subtree into an offscreen layer, and cards carry a gradient plus a
        // shadow: keeping the layer for the final frame and dropping it the
        // next makes the surface visibly shift colour.
        if (v >= 1) return child!;
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, widget.offset * (1 - v)),
            child: child,
          ),
        );
      },
      // Rasterise the card once and composite that, rather than redrawing its
      // gradient, shadow and text on every frame of the fade. Without this the
      // animation is doing real painting work each frame, which is what made it
      // stutter on the first pass through a screen - and Opacity skips painting
      // entirely at zero, so a card's first ever paint would otherwise land in
      // the middle of its own fade, at the worst possible moment.
      child: RepaintBoundary(child: widget.child),
    );
  }
}

/// Supplies hover and press state, plus a subtle press scale.
///
/// Colour changes are applied by the builder rather than tweened, which is what
/// keeps hover from flashing a bright frame on the way in.
class Hoverable extends StatefulWidget {
  const Hoverable({
    super.key,
    required this.builder,
    this.onTap,
    this.pressScale = 0.985,
    this.enabled = true,
    this.cursor = SystemMouseCursors.click,
    this.tooltip,
  });

  final Widget Function(bool hovered, bool pressed) builder;
  final VoidCallback? onTap;
  final double pressScale;
  final bool enabled;
  final MouseCursor cursor;
  final String? tooltip;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hovered = false;
  bool _pressed = false;

  void _set({bool? hovered, bool? pressed}) {
    if (!mounted) return;
    setState(() {
      if (hovered != null) _hovered = hovered;
      if (pressed != null) _pressed = pressed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final interactive = widget.enabled && (widget.onTap != null);
    Widget child = widget.builder(interactive && _hovered, interactive && _pressed);

    if (widget.pressScale != 1) {
      child = AnimatedScale(
        scale: interactive && _pressed ? widget.pressScale : 1.0,
        duration: Motion.fast,
        curve: Motion.curve,
        child: child,
      );
    }

    child = MouseRegion(
      cursor: interactive ? widget.cursor : MouseCursor.defer,
      onEnter: (_) => _set(hovered: true),
      onExit: (_) => _set(hovered: false, pressed: false),
      child: GestureDetector(
        onTapDown: interactive ? (_) => _set(pressed: true) : null,
        onTapUp: interactive ? (_) => _set(pressed: false) : null,
        onTapCancel: interactive ? () => _set(pressed: false) : null,
        onTap: interactive ? widget.onTap : null,
        child: child,
      ),
    );

    final tooltip = widget.tooltip;
    return tooltip == null ? child : Tooltip(message: tooltip, child: child);
  }
}
