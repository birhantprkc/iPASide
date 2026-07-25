import 'dart:async';

import '../services/update_planner.dart';
import '../services/update_service.dart';
import 'base_view_model.dart';

/// Drives the Updates card: check, download, install.
///
/// App-scoped, so the quiet check that runs at startup is already answered by
/// the time anyone opens Settings, and a session left running keeps noticing
/// releases published after it started.
class UpdateViewModel extends BaseViewModel {
  UpdateViewModel({required this._service, this._checkInterval = checkEvery}) {
    _timer = Timer.periodic(_checkInterval, _onTick);
  }

  /// How often a running app repeats the cheap version comparison.
  ///
  /// Long enough that an all-day session notices a release without ever looking
  /// like it is polling; nothing is downloaded either way.
  static const Duration checkEvery = Duration(hours: 6);

  static const List<String> _monthNames = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  final UpdateService _service;
  final Duration _checkInterval;

  Timer? _timer;
  bool _isBusy = false;
  bool _isDownloading = false;
  double _progress = 0;
  UpdateCheck? _last;
  DateTime? _lastCheckedAt;
  PendingUpdate? _pending;
  bool _launched = false;

  String get currentVersion => _service.currentVersion;

  /// Any request in flight (check or download).
  bool get isBusy => _isBusy;

  bool get isDownloading => _isDownloading;

  /// 0–1 while downloading.
  double get progress => _progress;

  /// The verified installer on disk, when there is one.
  PendingUpdate? get pending => _pending;

  bool get canDownload =>
      !_isBusy && _pending == null && _last?.outcome == UpdateOutcome.updateAvailable;

  bool get canInstall => !_isBusy && _pending != null;

  /// True once the installer has been handed off, so the card can stop
  /// pretending anything else is actionable.
  bool get hasLaunchedInstaller => _launched;

  String? get latestVersion => _last?.latestVersion;

  /// When a check last reached GitHub, or null before any check has.
  DateTime? get lastCheckedAt => _lastCheckedAt;

  /// One quiet line saying when the version above was last confirmed, or null
  /// while nothing has been confirmed yet.
  String? get lastCheckedLabel {
    final DateTime? checkedAt = _lastCheckedAt;
    if (checkedAt == null) return null;
    return describeLastChecked(checkedAt, DateTime.now());
  }

  /// Renders a successful check as `Last checked 11:48` on the day it happened
  /// and `Last checked 25 Jul` after that.
  ///
  /// A 24-hour clock and a short month name read the same everywhere, which is
  /// what keeps one line of text from needing a localisation package.
  static String describeLastChecked(DateTime checkedAt, DateTime now) {
    final DateTime at = checkedAt.toLocal();
    final DateTime today = now.toLocal();
    final bool sameDay =
        at.year == today.year && at.month == today.month && at.day == today.day;

    return sameDay
        ? 'Last checked ${_twoDigits(at.hour)}:${_twoDigits(at.minute)}'
        : 'Last checked ${at.day} ${_monthNames[at.month - 1]}';
  }

  /// Whether the last outcome was a refusal or failure rather than a normal state.
  bool get isProblem => switch (_last?.outcome) {
        UpdateOutcome.noSetupAsset ||
        UpdateOutcome.noChecksums ||
        UpdateOutcome.checksumMismatch ||
        UpdateOutcome.error =>
          true,
        _ => false,
      };

  /// One line describing where things stand, or null before the first check.
  String? get message {
    if (_isDownloading) return 'Downloading\u2026';
    if (_isBusy) return 'Checking for updates\u2026';
    if (_launched) return 'The installer is running. iPASide will restart when it finishes.';

    final result = _last;
    if (result == null) return null;

    return switch (result.outcome) {
      UpdateOutcome.upToDate => "You're on the latest version.",
      UpdateOutcome.updateAvailable =>
        'Version ${result.latestVersion} is available.',
      UpdateOutcome.readyToInstall =>
        'Version ${result.latestVersion} is downloaded and verified.',
      UpdateOutcome.noSetupAsset ||
      UpdateOutcome.noChecksums ||
      UpdateOutcome.checksumMismatch ||
      UpdateOutcome.error =>
        result.detail ?? 'The update could not be verified.',
    };
  }

  /// Cheap version comparison; safe to run at startup.
  Future<void> check() async {
    if (_isBusy) return;
    _isBusy = true;
    notify();

    final result = await _service.peekLatest();
    if (isDisposed) return;
    _last = result;
    _recordCheck(result);
    _isBusy = false;
    notify();
  }

  /// Downloads and verifies the newest release, then holds it for installation.
  Future<void> download() async {
    if (_isBusy) return;
    _isBusy = true;
    _isDownloading = true;
    _progress = 0;
    notify();

    final result = await _service.downloadUpdate(onProgress: (value) {
      if (isDisposed) return;
      _progress = value.clamp(0.0, 1.0);
      notify();
    });

    if (isDisposed) return;
    _last = result;
    _recordCheck(result);
    _pending = result.pending;
    _isDownloading = false;
    _isBusy = false;
    notify();
  }

  /// Hands the verified installer to the user's session.
  Future<void> install() async {
    final update = _pending;
    if (update == null || _isBusy) return;

    final started = await _service.installStaged(update);
    if (isDisposed) return;
    if (started) {
      _launched = true;
    } else {
      _last = const UpdateCheck(
        UpdateOutcome.error,
        detail: 'The installer could not be started.',
      );
    }
    notify();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// One turn of the periodic re-check.
  ///
  /// A download holds [isBusy] for its whole run and [check] declines to overlap
  /// one, so an in-flight download is never interrupted. Once the installer has
  /// been handed off there is nothing left to notice, so the asking stops.
  void _onTick(Timer timer) {
    if (_launched) return;
    unawaited(check());
  }

  /// Stamps [result] as the newest check that actually reached GitHub.
  ///
  /// Every outcome that read a published version counts, including the refusals
  /// that come after it; only [UpdateOutcome.error] means the check itself never
  /// landed, and a failure must not leave the card claiming a fresh one.
  void _recordCheck(UpdateCheck result) {
    if (result.outcome != UpdateOutcome.error) _lastCheckedAt = DateTime.now();
  }

  static String _twoDigits(int value) => value.toString().padLeft(2, '0');
}
