import '../engine/engine.dart';
import '../services/file_picker.dart';
import '../ui/shell/app_dialogs.dart';
import '../ui/shell/nav_destination.dart';
import 'base_view_model.dart';
import 'device_selection.dart';
import 'navigation_state.dart';

/// Home: three cards describing the phone an install would go to, plus the
/// pairing file those cards' device needs.
///
/// Device shows the lockdown identity from `device-info` (or the "no device"
/// empty state), Apple ID shows the session from `login --status`, and
/// Connection summarises the USB / Wi-Fi transports of the selected device. Each
/// card owns its own spinner, cleaned error and empty state, so one failing
/// engine call never blanks the screen.
///
/// Pairing is a fourth, full-width card: this PC's record for the selected
/// phone, whether it has Remote Pairing keys, which installed apps can use it,
/// and the import / export / place actions. It follows [DeviceSelection] the
/// same way Device does, because a pairing card that keeps describing the phone
/// that was selected when the screen opened is worse than no card.
///
/// All three status cards follow [DeviceSelection]. Retargeting from the sidebar
/// reloads the device card and re-derives the connection card, because a card
/// that keeps describing the phone that was selected when the screen opened is
/// worse than no card: it reads as the state of the device the user just chose.
class HomeViewModel extends BaseViewModel {
  HomeViewModel({
    required this._engine,
    required this._navigation,
    required this._devices,
    required this._picker,
    required this._dialogs,
  }) {
    _devices.addListener(_onSelectionChanged);
    // Independent loads: the account is not about a device and must not wait on one.
    _loadDevice();
    _loadAccount();
    _loadPairing();
  }

  static const _dash = '\u2014';

  final EngineApi _engine;
  final NavigationState _navigation;
  final DeviceSelection _devices;
  final FilePickerService _picker;
  final DialogService _dialogs;

  @override
  void dispose() {
    _devices.removeListener(_onSelectionChanged);
    super.dispose();
  }

  // ---- Device card ----

  bool _isDeviceLoading = true;
  String? _deviceError;
  bool _hasDevice = false;
  String deviceName = '';
  String deviceModel = '';
  String deviceIos = '';
  String deviceUdid = '';

  /// The (device, transport) pair the device card currently describes.
  ///
  /// Compared against the selection on every notification so that the many
  /// notifications which change neither — a refresh starting, names arriving —
  /// do not each cost a `device-info` round trip.
  String? _shownUdid;
  String? _shownConnection;

  /// Increments per load so a slow answer for a device the user has already
  /// moved on from is dropped instead of overwriting the newer one.
  int _deviceLoadToken = 0;

  bool get isDeviceLoading => _isDeviceLoading;
  String? get deviceError => _deviceError;
  bool get hasDevice => _hasDevice;
  bool get hasDeviceError => _deviceError != null;
  bool get isDeviceEmpty => !_isDeviceLoading && _deviceError == null && !_hasDevice;

  // ---- Apple ID card ----

  bool _isAccountLoading = true;
  String? _accountError;
  bool _isAuthenticated = false;
  String accountEmail = '';

  bool get isAccountLoading => _isAccountLoading;
  String? get accountError => _accountError;
  bool get isAuthenticated => _isAuthenticated;
  bool get hasAccountError => _accountError != null;
  bool get isAccountSignedOut =>
      !_isAccountLoading && _accountError == null && !_isAuthenticated;

  // ---- Connection card ----
  //
  // Read straight off DeviceSelection instead of a second `devices` call of its
  // own. The picker already enumerates, and two independent enumerations is how
  // this card came to say a phone was reachable over Wi-Fi while the sidebar had
  // a USB-only one selected. One enumeration cannot disagree with itself, and it
  // costs a round trip fewer per visit.

  bool get isConnectionLoading => !_devices.hasLoaded;
  String? get connectionError => _devices.error;
  bool get hasConnectionError => _devices.hasError;
  bool get hasVisibleDevice => _devices.selected != null;
  bool get isConnectionEmpty =>
      _devices.hasLoaded && !_devices.hasError && _devices.selected == null;

  // ---- Pairing file ----

  bool _isPairingLoading = true;
  String? _pairingError;
  PairingStatus? _pairing;
  bool _isPairingBusy = false;
  int _pairingLoadToken = 0;

  bool get isPairingLoading => _isPairingLoading;
  String? get pairingError => _pairingError;
  PairingStatus? get pairing => _pairing;
  bool get isPairingBusy => _isPairingBusy;
  bool get hasPairingError => _pairingError != null;
  bool get hasPairingPayload => _pairing?.hasPayload ?? false;
  bool get canExportPairing => hasPairingPayload && !_isPairingBusy;
  bool get canImportPairing => !_isPairingBusy && _devices.selectedUdid != null;
  bool get canPlacePairing =>
      hasPairingPayload &&
      !_isPairingBusy &&
      (_pairing?.deviceReachable ?? false);

  /// `connected` / `available` for a transport the selected device is on, and an
  /// em dash for one it is not.
  String get usbText => _transportText('USB', 'connected');
  String get wifiText => _transportText('Network', 'available');

  String _transportText(String transport, String present) {
    final DeviceTarget? target = _devices.selected;
    if (target == null) return _dash;
    return target.transports.contains(transport) ? present : _dash;
  }

  // ---- Commands ----

  Future<void> signOut() async {
    try {
      await _engine.logout();
    } on EngineShutdownException {
      return; // the app is closing
    } catch (error) {
      _accountError = BaseViewModel.errorText(error);
      notify();
      return;
    }
    // Re-navigating Home remounts the screen, which reloads all three cards.
    _navigation.navigateTo(NavKey.home);
  }

  void signIn() => _navigation.navigateTo(NavKey.signIn);
  void openSideload() => _navigation.navigateTo(NavKey.sideload);
  void openLibrary() => _navigation.navigateTo(NavKey.library);
  void openApps() => _navigation.navigateTo(NavKey.apps);
  void openDiagnostics() => _navigation.navigateTo(NavKey.diagnostics);

  Future<void> importPairing() async {
    if (!canImportPairing) return;
    final String? path = await _picker.pickPairingFile();
    if (path == null || isDisposed) return;

    _isPairingBusy = true;
    notify();
    try {
      final PairingImport result = await _engine.importPairing(
        path,
        udid: _devices.selectedUdid,
        connection: _devices.connectionArg,
      );
      if (isDisposed) return;
      await _loadPairing();
      if (isDisposed) return;
      await _dialogs.alert(
        title: 'Pairing file imported',
        message: result.hasRppairing
            ? 'This file includes Remote Pairing keys, so EscapeOS and StikDebug '
                'can use it on iOS 26.4 and later. Place it on the device to copy '
                'it into every supported app that is installed.'
            : (result.note ??
                'The pairing file was stored. Place it on the device to copy it '
                    'into every supported app that is installed.'),
      );
    } on EngineShutdownException {
      return;
    } catch (error) {
      if (!isDisposed) {
        await _dialogs.alert(
          title: 'Could not import pairing file',
          message: BaseViewModel.errorText(error),
        );
      }
    } finally {
      if (!isDisposed) {
        _isPairingBusy = false;
        notify();
      }
    }
  }

  Future<void> exportPairing() async {
    if (!canExportPairing) return;
    final String? path = await _picker.savePairingFile(
      suggestedName: 'pairingFile.plist',
    );
    if (path == null || isDisposed) return;

    _isPairingBusy = true;
    notify();
    try {
      final PairingExport result = await _engine.exportPairing(
        path,
        udid: _devices.selectedUdid,
        connection: _devices.connectionArg,
      );
      if (isDisposed) return;
      final String where = result.path ?? path;
      final String completeness = result.hasRppairing
          ? 'It includes Remote Pairing keys.'
          : 'It has this PC\u2019s USB pairing keys. EscapeOS on iOS 26.4 and '
              'later also needs Remote Pairing keys from an iLoader file.';
      await _dialogs.alert(
        title: 'Pairing file exported',
        message: 'Wrote $where. $completeness',
      );
    } on EngineShutdownException {
      return;
    } catch (error) {
      if (!isDisposed) {
        await _dialogs.alert(
          title: 'Could not export pairing file',
          message: BaseViewModel.errorText(error),
        );
      }
    } finally {
      if (!isDisposed) {
        _isPairingBusy = false;
        notify();
      }
    }
  }

  Future<void> placePairing() async {
    if (!canPlacePairing) return;
    final PairingStatus? snapshot = _pairing;
    if (snapshot == null) return;

    if (snapshot.consumers.isEmpty) {
      await _dialogs.alert(
        title: 'No supported apps installed',
        message:
            'Sideload EscapeOS, SideStore, AltStore, LiveContainer, or StikDebug, '
            'then place the pairing file. iPASide writes it into each app\u2019s '
            'Documents folder under the name that app looks for.',
      );
      return;
    }

    if (!snapshot.hasRppairing &&
        snapshot.consumers.any((PairingConsumerInfo c) => c.needsRppairing)) {
      final bool confirmed = await _dialogs.confirm(
        title: 'Place pairing file without Remote Pairing keys?',
        message:
            'This file has this PC\u2019s USB pairing keys, which SideStore and '
            'AltStore use. EscapeOS and StikDebug on iOS 26.4 and later also need '
            'Remote Pairing keys. Import an iLoader pairing file for this iPhone '
            'first, or place this file anyway for SideStore and older iOS.',
        confirmLabel: 'Place anyway',
      );
      if (!confirmed || isDisposed) return;
    }

    _isPairingBusy = true;
    notify();
    try {
      final PairingDelivery result = await _engine.deliverPairing(
        udid: _devices.selectedUdid,
        connection: _devices.connectionArg,
      );
      if (isDisposed) return;
      await _loadPairing();
      if (isDisposed) return;
      await _dialogs.alert(
        title: result.allPlaced
            ? 'Pairing file placed'
            : 'Pairing file could not be placed on every app',
        message: _placementMessage(result),
      );
    } on EngineShutdownException {
      return;
    } catch (error) {
      if (!isDisposed) {
        await _dialogs.alert(
          title: 'Could not place pairing file',
          message: BaseViewModel.errorText(error),
        );
      }
    } finally {
      if (!isDisposed) {
        _isPairingBusy = false;
        notify();
      }
    }
  }

  static String _placementMessage(PairingDelivery result) {
    if (result.placed.isEmpty) {
      return 'No supported apps are installed on this iPhone.';
    }
    final StringBuffer buffer = StringBuffer();
    for (final PairingPlacement item in result.placed) {
      final String name = item.name ?? item.bundleId ?? 'App';
      if (item.placed) {
        buffer.writeln('$name: wrote ${item.filename}.');
      } else {
        buffer.writeln('$name: ${item.error ?? 'could not be written'}.');
      }
    }
    if (result.note != null && !result.hasRppairing) {
      buffer.writeln();
      buffer.write(result.note);
    }
    return buffer.toString().trim();
  }

  // ---- Loads ----

  Future<void> _loadDevice() async {
    final int token = ++_deviceLoadToken;
    // Home is built on launch, before the shared enumeration has answered, so
    // the target is awaited rather than read: without that this is the one call
    // in the app that reliably goes out with no UDID.
    final String? udid = await _devices.targetUdid();
    final String? connection = _devices.connectionArg;
    if (isDisposed || token != _deviceLoadToken) return;
    _shownUdid = udid;
    _shownConnection = connection;

    try {
      final info = await _engine.deviceInfo(udid: udid, connection: connection);
      if (token != _deviceLoadToken) return; // retargeted while this was in flight

      // The engine returns an empty object when nothing is paired, which
      // parses to a record whose consumed fields are all null.
      final present = info.deviceName != null ||
          info.productType != null ||
          info.productVersion != null ||
          info.buildVersion != null ||
          info.uniqueDeviceId != null;
      if (present) {
        deviceName = info.deviceName ?? '';
        deviceModel = info.productType ?? '';
        deviceIos = '${info.productVersion ?? '?'} (${info.buildVersion ?? '?'})';
        deviceUdid = shortId(info.uniqueDeviceId);
        _hasDevice = true;
      }
    } catch (error) {
      if (token != _deviceLoadToken) return;
      if (!BaseViewModel.isShutdown(error)) {
        _deviceError = BaseViewModel.errorText(error);
      }
    } finally {
      if (token == _deviceLoadToken) {
        _isDeviceLoading = false;
        notify();
      }
    }
  }

  /// Re-reads the device card when the selection moves, and repaints regardless.
  ///
  /// The repaint is not incidental: the connection card is derived from
  /// [DeviceSelection], and this model is the only thing the screen watches, so
  /// without it the transports would go stale even though nothing was loading.
  void _onSelectionChanged() {
    if (isDisposed) return;

    final String? udid = _devices.selectedUdid;
    final String? connection = _devices.connectionArg;
    if (udid == _shownUdid && connection == _shownConnection) {
      notify();
      return;
    }

    _deviceError = null;
    _hasDevice = false;
    deviceName = '';
    deviceModel = '';
    deviceIos = '';
    deviceUdid = '';
    _isDeviceLoading = true;
    _pairing = null;
    _pairingError = null;
    _isPairingLoading = true;
    notify();
    _loadDevice();
    _loadPairing();
  }

  Future<void> _loadAccount() async {
    try {
      final status = await _engine.loginStatus();
      if (status.authenticated) {
        accountEmail = status.email ?? '';
        _isAuthenticated = true;
      }
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _accountError = BaseViewModel.errorText(error);
      }
    } finally {
      _isAccountLoading = false;
      notify();
    }
  }

  Future<void> _loadPairing() async {
    final int token = ++_pairingLoadToken;
    final String? udid = await _devices.targetUdid();
    final String? connection = _devices.connectionArg;
    if (isDisposed || token != _pairingLoadToken) return;

    if (udid == null || udid.isEmpty) {
      _pairing = null;
      _pairingError = null;
      _isPairingLoading = false;
      notify();
      return;
    }

    try {
      final PairingStatus status = await _engine.pairingStatus(
        udid: udid,
        connection: connection,
      );
      if (token != _pairingLoadToken) return;
      _pairing = status;
      _pairingError = null;
    } catch (error) {
      if (token != _pairingLoadToken) return;
      if (!BaseViewModel.isShutdown(error)) {
        _pairingError = BaseViewModel.errorText(error);
        _pairing = null;
      }
    } finally {
      if (token == _pairingLoadToken) {
        _isPairingLoading = false;
        notify();
      }
    }
  }

  /// Shortens a UDID to `8 chars … last 4`, leaving short ids untouched.
  static String shortId(String? id) {
    if (id == null || id.isEmpty) return '';
    return id.length > 14 ? '${id.substring(0, 8)}\u2026${id.substring(id.length - 4)}' : id;
  }
}
