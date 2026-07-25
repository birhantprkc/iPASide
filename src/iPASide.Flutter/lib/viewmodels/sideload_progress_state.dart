import '../engine/engine.dart';

/// The live state of a provision → sign → install run, in the terms the stepper
/// draws it.
///
/// This exists because two screens watch the same three phases: Sideload runs
/// them directly, and Library's refresh re-signs, which *is* a sideload. Folding
/// a frame in is the only place that knows a phase name maps to a step index, or
/// that a percentage is only meaningful during install — so it lives here once
/// rather than in each view model, where the two would drift the first time a
/// phase was added.
class SideloadProgressState {
  /// Creates a state; the default is a run that has not reported yet.
  const SideloadProgressState({
    this.activeIndex = 0,
    this.stepText,
    this.percent = 0,
    this.isIndeterminate = true,
  });

  /// A run that has been started but has produced no frame yet.
  static const SideloadProgressState starting = SideloadProgressState(
    stepText: 'Starting\u2026',
  );

  /// Fallback labels for a frame that carries a phase but no step text.
  static const List<String> phaseLabels = <String>[
    'Provisioning\u2026',
    'Signing\u2026',
    'Installing\u2026',
  ];

  /// Index of the step in progress: 0 provision, 1 sign, 2 install.
  final int activeIndex;

  /// What is happening right now, e.g. `Uploading to iPhone · 120 / 232 MB`.
  final String? stepText;

  /// Install progress, 0–100. Only meaningful when [isIndeterminate] is false.
  final double percent;

  /// Whether the work is unquantified, so the bar should sweep rather than fill.
  final bool isIndeterminate;

  /// The step index a phase name maps to, or null for one we do not draw.
  static int? indexForPhase(String? phase) => switch (phase) {
    'provision' => 0,
    'sign' => 1,
    'install' => 2,
    _ => null,
  };

  /// Folds one progress frame in, returning the state after it.
  ///
  /// A frame naming a phase we do not draw leaves the state untouched rather
  /// than resetting the stepper to somewhere misleading.
  SideloadProgressState apply(SideloadProgress progress) {
    final int? index = indexForPhase(progress.phase);
    if (index == null) return this;

    final String? step = progress.step;
    final double? reported = progress.percent;
    // Determinate only during install with a number: provision and sign are
    // Apple round trips and a zip, neither of which can honestly report a share
    // of the work done.
    final bool determinate = progress.phase == 'install' && reported != null;

    return SideloadProgressState(
      activeIndex: index,
      stepText: (step != null && step.isNotEmpty) ? step : phaseLabels[index],
      percent: determinate ? reported : percent,
      isIndeterminate: !determinate,
    );
  }

  /// The terminal state after a successful install.
  SideloadProgressState completed({String stepText = 'Installed'}) =>
      SideloadProgressState(
        activeIndex: phaseLabels.length - 1,
        stepText: stepText,
        percent: 100,
        isIndeterminate: false,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SideloadProgressState &&
          other.activeIndex == activeIndex &&
          other.stepText == stepText &&
          other.percent == percent &&
          other.isIndeterminate == isIndeterminate;

  @override
  int get hashCode =>
      Object.hash(activeIndex, stepText, percent, isIndeterminate);

  @override
  String toString() =>
      'SideloadProgressState(activeIndex: $activeIndex, stepText: $stepText, '
      'percent: $percent, isIndeterminate: $isIndeterminate)';
}
