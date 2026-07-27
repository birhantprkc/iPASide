import '../engine/engine.dart';
import '../services/settings_store.dart';
import '../ui/shell/nav_destination.dart';
import 'base_view_model.dart';
import 'device_selection.dart';
import 'navigation_state.dart';
import 'sideload_progress_state.dart';

/// The LiveContainer screen.
///
/// Long-lived, for the same reason the Sideload session is: setting LiveContainer
/// up takes half a minute of downloading, signing and installing, and navigating
/// away mid-run must not throw the progress — or the outcome — away.
///
/// What it is for: LiveContainer runs other apps inside itself, so the phone
/// counts one installed app however many are loaded into it. That is the only way
/// past the three-app limit a free Apple ID imposes. iPASide signs it with the
/// entitlements it needs and hands it the signing certificate, which is what lets
/// it sign guest apps on device.
class LiveContainerViewModel extends BaseViewModel {
  LiveContainerViewModel({
    required this._engine,
    required this._navigation,
    required this._settings,
    required this._devices,
  });

  final EngineApi _engine;
  final NavigationState _navigation;

  /// Read per run, never cached: this model is app-scoped and outlives any visit
  /// to Settings, so a value read in the constructor would go stale the moment the
  /// user changed it.
  final SettingsStore _settings;

  /// Also read per run — the target can change, or be unplugged, between runs.
  final DeviceSelection _devices;

  /// The phases this flow reports, for the stepper to label itself from.
  static const ProgressSchedule schedule = ProgressSchedule.liveContainer;

  LiveContainerStatus? _status;
  bool _isLoading = false;
  bool _isRunning = false;
  String? _error;

  SideloadProgressState _progress = const SideloadProgressState();
  LiveContainerSetupResult? _result;
  String? _failureMessage;

  /// What the device says, or null before the first look.
  LiveContainerStatus? get status => _status;

  /// Whether a status read is in flight.
  bool get isLoading => _isLoading;

  /// Whether a setup is running, so the button should be busy and inputs frozen.
  bool get isRunning => _isRunning;

  /// A status-read failure, which is not the same as a setup failure.
  String? get error => _error;

  /// Live progress of the current or most recent run.
  SideloadProgressState get progress => _progress;

  /// The stepper is worth drawing once a run has started, and stays afterwards so
  /// the finished state remains readable.
  bool get showStepper => _isRunning || _result != null || _failureMessage != null;

  /// The outcome of the last completed run.
  LiveContainerSetupResult? get result => _result;

  /// Why the last run failed, or null.
  String? get failureMessage => _failureMessage;

  /// Whether the run finished and installed.
  bool get isSucceeded => _result?.isInstalled ?? false;

  /// Whether the last run failed.
  bool get isFailed => _failureMessage != null;

  /// Whether LiveContainer is on the device, as far as the last read knows.
  bool get isInstalled => _status?.installed ?? false;

  /// Whether the user still has to open LiveContainer to finish the import.
  ///
  /// True from either direction: a run that just staged an import, or a status
  /// read that found one still waiting from an earlier run.
  bool get needsLaunch =>
      (_result?.launchRequired ?? false) || (_status?.certificatePending ?? false);

  /// What the user has to do by hand, when the certificate could not be imported
  /// automatically. Null when nothing is needed.
  String? get manualInstructions {
    final LiveContainerCertificate? certificate = _result?.certificate;
    if (certificate == null || certificate.automatic) return null;
    return certificate.instructions;
  }

  /// Reads the device's LiveContainer state.
  Future<void> load() async {
    if (_isLoading) return;
    _isLoading = true;
    _error = null;
    notify();

    try {
      _status = await _engine.liveContainerStatus(
        udid: await _devices.targetUdid(),
        connection: _devices.connectionArg,
      );
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _error = BaseViewModel.errorText(error);
      }
    } finally {
      _isLoading = false;
      notify();
    }
  }

  /// Downloads, signs, installs LiveContainer and hands it the certificate.
  ///
  /// Sends the user to sign-in first when there is no session, because every step
  /// after the download needs Apple: there is no point downloading 4 MB to fail.
  Future<void> setUp() async {
    if (_isRunning) return;

    // Claimed before the first await, not after the sign-in probe: the button is
    // disabled while a run is on, but the guard has to hold on its own, or two
    // calls in the same frame would both get past it and install twice.
    _result = null;
    _failureMessage = null;
    _isRunning = true;
    _progress = SideloadProgressState.starting;
    notify();

    try {
      LoginStatus? login;
      try {
        login = await _engine.loginStatus();
      } catch (error) {
        if (BaseViewModel.isShutdown(error)) return;
        // A failed probe counts as signed out.
      }
      if (login == null || !login.authenticated) {
        _navigation.navigateTo(NavKey.signIn);
        return;
      }

      final SignedIpaSettings signed = _settings.loadSignedIpa();
      _result = await _engine.liveContainerSetup(
        udid: await _devices.targetUdid(),
        connection: _devices.connectionArg,
        keepSigned: signed.keep,
        signedDirectory: signed.directory,
        onProgress: _onProgress,
      );
      if (_result!.isInstalled) {
        _progress = _progress.completed(
          stepText: 'Installed',
          schedule: schedule,
        );
      }
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _failureMessage = BaseViewModel.errorText(error);
      }
    } finally {
      _isRunning = false;
      notify();
    }

    // Re-read rather than infer: the run reports what it did, the device reports
    // what is true, and only the second knows whether an import is still waiting.
    await load();
  }

  void _onProgress(SideloadProgress progress) {
    final SideloadProgressState next =
        _progress.apply(progress, schedule: schedule);
    if (next == _progress) return; // a phase this flow does not draw
    _progress = next;
    notify();
  }
}
