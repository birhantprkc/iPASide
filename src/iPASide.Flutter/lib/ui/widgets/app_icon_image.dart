import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// An app's icon, falling back to a neutral placeholder tile.
///
/// Takes already-decoded bytes: decoding and caching belong to the icon cache,
/// so this stays a pure paint and is safe to rebuild freely.
class AppIconImage extends StatelessWidget {
  const AppIconImage({
    super.key,
    required this.bytes,
    this.size = Sizes.appIcon,
    this.radius,
  });

  /// The proportion of an icon's side that iOS rounds off.
  ///
  /// Scaling the radius with the tile is what makes a 40px icon in a list read as
  /// the same shape as a 56px one on the Sideload card; a radius fixed in pixels
  /// looks tighter the larger the tile gets, which is how the two lists ended up
  /// disagreeing about it.
  static const double _cornerRatio = 0.2237;

  final Uint8List? bytes;
  final double size;

  /// Corner radius, defaulting to iOS's own proportion of [size].
  final double? radius;

  double get _radius => radius ?? size * _cornerRatio;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final data = bytes;

    if (data == null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: p.bg2,
          borderRadius: BorderRadius.circular(_radius),
          border: Border.all(color: p.hairline),
        ),
        child: Icon(
          Icons.inventory_2_outlined,
          size: size * 0.45,
          color: p.textMuted,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(_radius),
      child: Image.memory(
        data,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // Icons are already in memory; a fade would flicker on every rebuild.
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
