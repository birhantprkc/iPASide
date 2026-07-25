// Lean models mapping ONLY the engine fields the UI consumes, ported from
// iPASide.App/Engine/Models.cs.
//
// Wire keys are spelled out per field and never fuzzy-matched: the engine mixes
// conventions (lockdown values are PascalCase, inventory values are snake_case,
// `apps` returns a dict keyed by bundle id).
//
// Two deliberate departures from the C# records:
//  * Parsing is tolerant. A missing or wrongly-typed field degrades to
//    null/false/empty; System.Text.Json would have thrown and taken the whole
//    screen with it.
//  * List-valued fields are never null (the C# records used nullable lists that
//    every caller coalesced). They must be treated as read-only.
//
// Value equality is implemented by hand so the UI can suppress rebuilds by
// comparing snapshots, the way it could with C# records.

import 'json_utils.dart';

/// Lockdown device identity, using the PascalCase keys pymobiledevice3 returns.
class DeviceInfo {
  /// Creates a device identity.
  const DeviceInfo({
    this.deviceName,
    this.productType,
    this.productVersion,
    this.buildVersion,
    this.uniqueDeviceId,
  });

  /// Parses one `device-info` payload.
  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        deviceName: jsonString(json, 'DeviceName'),
        productType: jsonString(json, 'ProductType'),
        productVersion: jsonString(json, 'ProductVersion'),
        buildVersion: jsonString(json, 'BuildVersion'),
        uniqueDeviceId: jsonString(json, 'UniqueDeviceID'),
      );

  /// User-chosen device name, e.g. `iOS_hAT's iPhone`.
  final String? deviceName;

  /// Hardware model identifier, e.g. `iPhone10,2`.
  final String? productType;

  /// iOS version, e.g. `16.7.15`.
  final String? productVersion;

  /// iOS build number, e.g. `20H380`.
  final String? buildVersion;

  /// 40-character UDID.
  final String? uniqueDeviceId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceInfo &&
          other.deviceName == deviceName &&
          other.productType == productType &&
          other.productVersion == productVersion &&
          other.buildVersion == buildVersion &&
          other.uniqueDeviceId == uniqueDeviceId;

  @override
  int get hashCode => Object.hash(
        deviceName,
        productType,
        productVersion,
        buildVersion,
        uniqueDeviceId,
      );

  @override
  String toString() => 'DeviceInfo(deviceName: $deviceName, '
      'productType: $productType, productVersion: $productVersion, '
      'buildVersion: $buildVersion, uniqueDeviceId: $uniqueDeviceId)';
}

/// One entry from `devices`.
///
/// usbmux reports one entry PER TRANSPORT, so a phone that is plugged in and
/// also reachable over Wi-Fi appears twice under the same [serial]. That is one
/// device with two ways in, not two devices; grouping them back into physical
/// devices is [DeviceSelection]'s job.
class DeviceEntry {
  /// Creates a device list entry.
  const DeviceEntry({this.serial, this.connectionType});

  /// Parses one element of the `devices` array.
  ///
  /// `device_id` is deliberately not read: it is usbmux's per-transport handle,
  /// not an identity — the same phone has a different one on each transport and
  /// they change across reconnects, so nothing in the UI can use it.
  factory DeviceEntry.fromJson(Map<String, dynamic> json) => DeviceEntry(
        serial: jsonString(json, 'serial'),
        connectionType: jsonString(json, 'connection_type'),
      );

  /// The device's UDID, and the only thing that identifies it across
  /// transports. Null for an entry usbmux could not name, which can never be a
  /// target.
  final String? serial;

  /// `USB` or `Network`, as reported by usbmux.
  final String? connectionType;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceEntry &&
          other.serial == serial &&
          other.connectionType == connectionType;

  @override
  int get hashCode => Object.hash(serial, connectionType);

  @override
  String toString() =>
      'DeviceEntry(serial: $serial, connectionType: $connectionType)';
}

/// Result of `login --status`.
class LoginStatus {
  /// Creates a session status.
  const LoginStatus({
    this.authenticated = false,
    this.email,
    this.teamId,
    this.accountCount = 0,
  });

  /// Parses a `login --status` payload.
  factory LoginStatus.fromJson(Map<String, dynamic> json) => LoginStatus(
        authenticated: jsonBool(json, 'authenticated'),
        email: jsonString(json, 'email'),
        teamId: jsonString(json, 'team_id'),
        accountCount: jsonInt(json, 'account_count'),
      );

  /// Whether a usable Apple ID session is cached.
  final bool authenticated;

  /// The Apple ID in use, when there is one.
  final String? email;

  /// The developer team that account provisions under, once it has provisioned.
  final String? teamId;

  /// How many Apple IDs are signed in, in use or not.
  final int accountCount;

  /// Whether there is more than one account to choose between.
  bool get hasChoice => accountCount > 1;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LoginStatus &&
          other.authenticated == authenticated &&
          other.email == email &&
          other.teamId == teamId &&
          other.accountCount == accountCount;

  @override
  int get hashCode => Object.hash(authenticated, email, teamId, accountCount);

  @override
  String toString() => 'LoginStatus(authenticated: $authenticated, '
      'email: $email, teamId: $teamId, accountCount: $accountCount)';
}

/// One Apple ID that is signed in, from `login --accounts`.
///
/// Several can be kept at once. Which one is [active] decides who signs a new
/// sideload; a refresh instead uses whichever account provisions under the team
/// that signed the app originally, because re-signing it with a different team's
/// identity leaves iOS unable to install it over the copy already installed.
class AppleAccount {
  /// Creates an account entry.
  const AppleAccount({
    required this.email,
    this.teamId,
    this.active = false,
  });

  /// Parses one entry of a `login --accounts` payload.
  factory AppleAccount.fromJson(Map<String, dynamic> json) => AppleAccount(
        email: jsonString(json, 'email') ?? '',
        teamId: jsonString(json, 'team_id'),
        active: jsonBool(json, 'active'),
      );

  /// The Apple ID.
  final String email;

  /// The developer team it provisions under, once it has provisioned once.
  final String? teamId;

  /// Whether this is the account new sideloads will use.
  final bool active;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppleAccount &&
          other.email == email &&
          other.teamId == teamId &&
          other.active == active;

  @override
  int get hashCode => Object.hash(email, teamId, active);

  @override
  String toString() =>
      'AppleAccount(email: $email, teamId: $teamId, active: $active)';
}

/// Result of `login` / `login --code`.
class LoginResult {
  /// Creates a login outcome.
  const LoginResult({this.status, this.method});

  /// Parses a `login` payload.
  factory LoginResult.fromJson(Map<String, dynamic> json) => LoginResult(
        status: jsonString(json, 'status'),
        method: jsonString(json, 'method'),
      );

  /// `2fa_required` or `authenticated`.
  final String? status;

  /// How the verification code was delivered, when 2FA is required.
  final String? method;

  /// Whether the engine is waiting for a two-factor code.
  bool get requiresTwoFactor => status == '2fa_required';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LoginResult && other.status == status && other.method == method;

  @override
  int get hashCode => Object.hash(status, method);

  @override
  String toString() => 'LoginResult(status: $status, method: $method)';
}

/// Result of `inspect`.
class IpaInspection {
  /// Creates an IPA inspection.
  const IpaInspection({
    this.bundleId,
    this.displayName,
    this.icon,
    this.version,
    this.minimumOs,
    this.frameworks = const <String>[],
    this.extensions = const <String>[],
    this.hasScInfo = false,
  });

  /// Parses an `inspect` payload.
  factory IpaInspection.fromJson(Map<String, dynamic> json) => IpaInspection(
        bundleId: jsonString(json, 'bundle_id'),
        displayName: jsonString(json, 'display_name'),
        icon: jsonString(json, 'icon'),
        version: jsonString(json, 'version'),
        minimumOs: jsonString(json, 'minimum_os'),
        frameworks: jsonStringList(json, 'frameworks'),
        extensions: jsonStringList(json, 'extensions'),
        hasScInfo: jsonBool(json, 'has_sc_info'),
      );

  /// The IPA's own bundle identifier, before any override.
  final String? bundleId;

  /// `CFBundleDisplayName`, falling back to `CFBundleName`.
  final String? displayName;

  /// Base64-encoded PNG app icon, when the IPA carries one.
  final String? icon;

  /// `CFBundleShortVersionString`.
  final String? version;

  /// `MinimumOSVersion`.
  final String? minimumOs;

  /// Embedded framework names. Read-only.
  final List<String> frameworks;

  /// App-extension (`.appex`) names, including any watch app. Read-only.
  final List<String> extensions;

  /// Whether an `SC_Info` directory is present, i.e. the payload is FairPlay
  /// encrypted and cannot be re-signed.
  final bool hasScInfo;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IpaInspection &&
          other.bundleId == bundleId &&
          other.displayName == displayName &&
          other.icon == icon &&
          other.version == version &&
          other.minimumOs == minimumOs &&
          _listEquals(other.frameworks, frameworks) &&
          _listEquals(other.extensions, extensions) &&
          other.hasScInfo == hasScInfo;

  @override
  int get hashCode => Object.hash(
        bundleId,
        displayName,
        icon,
        version,
        minimumOs,
        Object.hashAll(frameworks),
        Object.hashAll(extensions),
        hasScInfo,
      );

  @override
  String toString() => 'IpaInspection(bundleId: $bundleId, '
      'displayName: $displayName, version: $version, '
      'minimumOs: $minimumOs, frameworks: ${frameworks.length}, '
      'extensions: ${extensions.length}, hasScInfo: $hasScInfo, '
      'icon: ${_describeIcon(icon)})';
}

/// One value from the `apps` dict (which is keyed by bundle id).
class InstalledApp {
  /// Creates an installed-app entry.
  const InstalledApp({this.name, this.version});

  /// Parses one value of the `apps` dict.
  factory InstalledApp.fromJson(Map<String, dynamic> json) => InstalledApp(
        name: jsonString(json, 'name'),
        version: jsonString(json, 'version'),
      );

  /// Display name as installed on the device.
  final String? name;

  /// Installed short version string.
  final String? version;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InstalledApp && other.name == name && other.version == version;

  @override
  int get hashCode => Object.hash(name, version);

  @override
  String toString() => 'InstalledApp(name: $name, version: $version)';
}

/// The recorded sideload options carried on an [InstallRecord].
class InstallOptions {
  /// Creates a recorded option set.
  const InstallOptions({this.dylibs = const <String>[]});

  /// Parses the `options` object of an `installs` entry.
  factory InstallOptions.fromJson(Map<String, dynamic> json) =>
      InstallOptions(dylibs: jsonStringList(json, 'dylibs'));

  /// Dylib paths injected during the original sideload. Read-only.
  final List<String> dylibs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InstallOptions && _listEquals(other.dylibs, dylibs);

  @override
  int get hashCode => Object.hashAll(dylibs);

  @override
  String toString() => 'InstallOptions(dylibs: $dylibs)';
}

/// One entry from `installs`: a recorded sideload plus its expiry.
class InstallRecord {
  /// Creates a library record.
  const InstallRecord({
    this.bundleId,
    this.name,
    this.icon,
    this.daysLeft,
    this.expired = false,
    this.options,
    this.udid,
  });

  /// Parses one element of the `installs` array.
  factory InstallRecord.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? options = asJsonObject(json['options']);
    return InstallRecord(
      bundleId: jsonString(json, 'bundle_id'),
      name: jsonString(json, 'name'),
      icon: jsonString(json, 'icon'),
      daysLeft: jsonDouble(json, 'days_left'),
      expired: jsonBool(json, 'expired'),
      options: options == null ? null : InstallOptions.fromJson(options),
      udid: jsonString(json, 'udid'),
    );
  }

  /// Installed bundle identifier (the override, when one was used).
  final String? bundleId;

  /// Display name recorded at sideload time.
  final String? name;

  /// Base64-encoded PNG app icon, when one was recorded.
  final String? icon;

  /// Days until the free provisioning profile expires; null when unknown.
  final double? daysLeft;

  /// Whether the recorded profile has already expired.
  final bool expired;

  /// Options the app was sideloaded with; null when the record predates them.
  final InstallOptions? options;

  /// The device this app was installed onto.
  ///
  /// Row actions are issued against this rather than whichever device happens to
  /// be selected now, so removing an app cannot uninstall it from another phone.
  final String? udid;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InstallRecord &&
          other.bundleId == bundleId &&
          other.name == name &&
          other.icon == icon &&
          other.daysLeft == daysLeft &&
          other.expired == expired &&
          other.options == options;

  @override
  int get hashCode =>
      Object.hash(bundleId, name, icon, daysLeft, expired, options);

  @override
  String toString() => 'InstallRecord(bundleId: $bundleId, name: $name, '
      'daysLeft: $daysLeft, expired: $expired, options: $options, '
      'icon: ${_describeIcon(icon)})';
}

/// Per-app outcome inside a [RefreshSummary].
class RefreshEntry {
  /// Creates a per-app refresh outcome.
  const RefreshEntry({this.bundleId, this.status, this.error});

  /// Parses one element of the `refreshed` array.
  factory RefreshEntry.fromJson(Map<String, dynamic> json) => RefreshEntry(
        bundleId: jsonString(json, 'bundle_id'),
        status: jsonString(json, 'status'),
        error: jsonString(json, 'error'),
      );

  /// The app that was refreshed.
  final String? bundleId;

  /// `refreshed`, `skipped`, `error`, ...
  final String? status;

  /// Raw failure text; only meaningful when [status] is `error`.
  final String? error;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RefreshEntry &&
          other.bundleId == bundleId &&
          other.status == status &&
          other.error == error;

  @override
  int get hashCode => Object.hash(bundleId, status, error);

  @override
  String toString() =>
      'RefreshEntry(bundleId: $bundleId, status: $status, error: $error)';
}

/// Result of `refresh`.
///
/// The engine returns `ok: true` even when individual apps fail, so callers
/// MUST inspect [refreshed].
class RefreshSummary {
  /// Creates a refresh summary.
  const RefreshSummary({this.refreshed = const <RefreshEntry>[]});

  /// Parses a `refresh` payload.
  factory RefreshSummary.fromJson(Map<String, dynamic> json) => RefreshSummary(
        refreshed: jsonObjectList(json, 'refreshed', RefreshEntry.fromJson),
      );

  /// One entry per app the run touched. Read-only.
  final List<RefreshEntry> refreshed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RefreshSummary && _listEquals(other.refreshed, refreshed);

  @override
  int get hashCode => Object.hashAll(refreshed);

  @override
  String toString() => 'RefreshSummary(refreshed: $refreshed)';
}

/// Result of `sideload` (status is `installed` on success).
class SideloadResult {
  /// Creates a sideload outcome.
  const SideloadResult({this.status, this.name, this.bundleId});

  /// Parses a `sideload` payload.
  factory SideloadResult.fromJson(Map<String, dynamic> json) => SideloadResult(
        status: jsonString(json, 'status'),
        name: jsonString(json, 'name'),
        bundleId: jsonString(json, 'bundle_id'),
      );

  /// `installed` on success.
  final String? status;

  /// Display name the app was installed under.
  final String? name;

  /// Bundle identifier the app was installed under.
  final String? bundleId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SideloadResult &&
          other.status == status &&
          other.name == name &&
          other.bundleId == bundleId;

  @override
  int get hashCode => Object.hash(status, name, bundleId);

  @override
  String toString() => 'SideloadResult(status: $status, name: $name, '
      'bundleId: $bundleId)';
}

/// One file in the signed-IPA directory, from a `signed` listing.
class SignedIpaFile {
  /// Creates a signed-IPA file entry.
  const SignedIpaFile({this.name, this.bytes = 0, this.modified});

  /// Parses one element of the `files` array.
  factory SignedIpaFile.fromJson(Map<String, dynamic> json) => SignedIpaFile(
        name: jsonString(json, 'name'),
        bytes: jsonInt(json, 'bytes'),
        modified: jsonDateTime(json, 'modified'),
      );

  /// File name inside the directory, not a full path.
  final String? name;

  /// Size on disk; 0 when the engine did not report one.
  final int bytes;

  /// When it was written, parsed from the engine's ISO 8601 string; null when
  /// that string was missing or unreadable.
  final DateTime? modified;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SignedIpaFile &&
          other.name == name &&
          other.bytes == bytes &&
          other.modified == modified;

  @override
  int get hashCode => Object.hash(name, bytes, modified);

  @override
  String toString() => 'SignedIpaFile(name: $name, bytes: $bytes, '
      'modified: $modified)';
}

/// Result of `signed`: what is sitting in the signed-IPA directory right now.
///
/// [count] and [bytes] are the engine's own totals rather than something derived
/// from [files], so a listing that had to skip an unreadable entry still reports
/// the truth about the folder.
class SignedIpaListing {
  /// Creates a signed-IPA listing.
  const SignedIpaListing({
    this.directory,
    this.count = 0,
    this.bytes = 0,
    this.files = const <SignedIpaFile>[],
  });

  /// Parses a `signed` payload.
  factory SignedIpaListing.fromJson(Map<String, dynamic> json) =>
      SignedIpaListing(
        directory: jsonString(json, 'directory'),
        count: jsonInt(json, 'count'),
        bytes: jsonInt(json, 'bytes'),
        files: jsonObjectList(json, 'files', SignedIpaFile.fromJson),
      );

  /// The directory that was listed — the engine's default unless one was asked
  /// for.
  final String? directory;

  /// How many signed `.ipa`s are stored.
  final int count;

  /// What they occupy in total.
  final int bytes;

  /// One entry per file. Read-only.
  final List<SignedIpaFile> files;

  /// Whether the directory holds nothing worth offering to delete.
  bool get isEmpty => count == 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SignedIpaListing &&
          other.directory == directory &&
          other.count == count &&
          other.bytes == bytes &&
          _listEquals(other.files, files);

  @override
  int get hashCode =>
      Object.hash(directory, count, bytes, Object.hashAll(files));

  @override
  String toString() => 'SignedIpaListing(directory: $directory, '
      'count: $count, bytes: $bytes, files: ${files.length})';
}

/// Result of `signed --clean`.
class SignedIpaCleanup {
  /// Creates a cleanup outcome.
  const SignedIpaCleanup({this.directory, this.removed = 0, this.bytesFreed = 0});

  /// Parses a `signed --clean` payload.
  factory SignedIpaCleanup.fromJson(Map<String, dynamic> json) =>
      SignedIpaCleanup(
        directory: jsonString(json, 'directory'),
        removed: jsonInt(json, 'removed'),
        bytesFreed: jsonInt(json, 'bytes_freed'),
      );

  /// The directory that was emptied.
  final String? directory;

  /// How many files were deleted.
  final int removed;

  /// How much space that reclaimed.
  final int bytesFreed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SignedIpaCleanup &&
          other.directory == directory &&
          other.removed == removed &&
          other.bytesFreed == bytesFreed;

  @override
  int get hashCode => Object.hash(directory, removed, bytesFreed);

  @override
  String toString() => 'SignedIpaCleanup(directory: $directory, '
      'removed: $removed, bytesFreed: $bytesFreed)';
}

/// One injectable dylib resolved from a `.deb` or `.dylib` by `resolve-tweak`.
class TweakDylib {
  /// Creates a resolved dylib.
  const TweakDylib({
    this.path,
    this.name,
    this.arches = const <String>[],
    this.fromDeb,
  });

  /// Parses one element of the `dylibs` array.
  factory TweakDylib.fromJson(Map<String, dynamic> json) => TweakDylib(
        path: jsonString(json, 'path'),
        name: jsonString(json, 'name'),
        arches: jsonStringList(json, 'arches'),
        fromDeb: jsonString(json, 'from_deb'),
      );

  /// Absolute path of the extracted dylib; the de-duplication key.
  final String? path;

  /// File name shown in the tweak list.
  final String? name;

  /// Mach-O architectures the dylib provides. Read-only.
  final List<String> arches;

  /// The `.deb` this dylib was extracted from, when it came from one.
  final String? fromDeb;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TweakDylib &&
          other.path == path &&
          other.name == name &&
          _listEquals(other.arches, arches) &&
          other.fromDeb == fromDeb;

  @override
  int get hashCode => Object.hash(path, name, Object.hashAll(arches), fromDeb);

  @override
  String toString() => 'TweakDylib(path: $path, name: $name, '
      'arches: $arches, fromDeb: $fromDeb)';
}

/// One row of a [DoctorReport].
class DoctorCheck {
  /// Creates a diagnostic row.
  const DoctorCheck({this.status, this.name, this.detail});

  /// Parses one element of the `checks` array.
  factory DoctorCheck.fromJson(Map<String, dynamic> json) => DoctorCheck(
        status: jsonString(json, 'status'),
        name: jsonString(json, 'name'),
        detail: jsonString(json, 'detail'),
      );

  /// `ok`, `warn` or `fail`.
  final String? status;

  /// What was checked.
  final String? name;

  /// Human-readable outcome, including remediation hints.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DoctorCheck &&
          other.status == status &&
          other.name == name &&
          other.detail == detail;

  @override
  int get hashCode => Object.hash(status, name, detail);

  @override
  String toString() =>
      'DoctorCheck(status: $status, name: $name, detail: $detail)';
}

/// Result of `doctor`.
class DoctorReport {
  /// Creates a diagnostic report.
  const DoctorReport({this.overall, this.checks = const <DoctorCheck>[]});

  /// Parses a `doctor` payload.
  factory DoctorReport.fromJson(Map<String, dynamic> json) => DoctorReport(
        overall: jsonString(json, 'overall'),
        checks: jsonObjectList(json, 'checks', DoctorCheck.fromJson),
      );

  /// `ok`, `warn` or `fail`; the worst status across [checks].
  final String? overall;

  /// One row per environment check. Read-only.
  final List<DoctorCheck> checks;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DoctorReport &&
          other.overall == overall &&
          _listEquals(other.checks, checks);

  @override
  int get hashCode => Object.hash(overall, Object.hashAll(checks));

  @override
  String toString() => 'DoctorReport(overall: $overall, checks: $checks)';
}

/// Result of `anisette`.
class AnisetteStatus {
  /// Creates an anisette status.
  const AnisetteStatus({this.packageVersion, this.stateCached = false});

  /// Parses an `anisette` payload.
  factory AnisetteStatus.fromJson(Map<String, dynamic> json) => AnisetteStatus(
        packageVersion: jsonString(json, 'package_version'),
        stateCached: jsonBool(json, 'state_cached'),
      );

  /// Version of the `anisette` Python package in use.
  final String? packageVersion;

  /// Whether provisioned anisette state is already cached on disk.
  final bool stateCached;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnisetteStatus &&
          other.packageVersion == packageVersion &&
          other.stateCached == stateCached;

  @override
  int get hashCode => Object.hash(packageVersion, stateCached);

  @override
  String toString() => 'AnisetteStatus(packageVersion: $packageVersion, '
      'stateCached: $stateCached)';
}

/// Result of `apple-support`: the state of Apple's device stack on this machine.
///
/// [state] is a vocabulary rather than a flag because the remedy differs for each
/// value — nothing, an elevated service start, or a ~200 MB install — and a screen
/// that cannot tell "stopped" from "never installed" offers the wrong button. A
/// value this build does not know is treated as "no opinion": [isRunning] is false
/// and so is [blocksDevices], so a newer engine can add one without a screen
/// blocking work over a word it cannot read.
class AppleSupportStatus {
  /// Creates an Apple-support status.
  const AppleSupportStatus({
    this.state,
    this.serviceName,
    this.serviceState,
    this.itunesInstalled = false,
    this.itunesVersion,
    this.detail,
  });

  /// Parses an `apple-support` payload.
  factory AppleSupportStatus.fromJson(Map<String, dynamic> json) =>
      AppleSupportStatus(
        state: jsonString(json, 'state'),
        serviceName: jsonString(json, 'service_name'),
        serviceState: jsonString(json, 'service_state'),
        itunesInstalled: jsonBool(json, 'itunes_installed'),
        itunesVersion: jsonString(json, 'itunes_version'),
        detail: jsonString(json, 'detail'),
      );

  /// The service is up and device I/O works.
  static const String running = 'running';

  /// The service is installed but not running; starting it needs elevation.
  static const String stopped = 'stopped';

  /// The service is not installed; iTunes has to be.
  static const String missing = 'missing';

  /// Not a Windows host, so there is no such service to have.
  static const String unsupported = 'unsupported';

  /// [running], [stopped], [missing] or [unsupported].
  final String? state;

  /// The Windows service that was looked for.
  final String? serviceName;

  /// Its raw Windows state (`RUNNING`, `STOPPED`, …); null when it is absent.
  final String? serviceState;

  /// Whether iTunes itself looks installed, which decides whether the fix is an
  /// install or a repair.
  final bool itunesInstalled;

  /// iTunes' registered version, when it is installed.
  final String? itunesVersion;

  /// One sentence, written by the engine to be shown verbatim.
  final String? detail;

  bool get isRunning => state == running;

  bool get isStopped => state == stopped;

  bool get isMissing => state == missing;

  bool get isUnsupported => state == unsupported;

  /// Whether this machine cannot reach an iPhone at all.
  ///
  /// True for both bad states, because usbmux brokers Wi-Fi as well as USB: with
  /// the service down there is no transport, not merely no cable.
  bool get blocksDevices => isStopped || isMissing;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppleSupportStatus &&
          other.state == state &&
          other.serviceName == serviceName &&
          other.serviceState == serviceState &&
          other.itunesInstalled == itunesInstalled &&
          other.itunesVersion == itunesVersion &&
          other.detail == detail;

  @override
  int get hashCode => Object.hash(
        state,
        serviceName,
        serviceState,
        itunesInstalled,
        itunesVersion,
        detail,
      );

  @override
  String toString() => 'AppleSupportStatus(state: $state, '
      'serviceState: $serviceState, itunesInstalled: $itunesInstalled, '
      'itunesVersion: $itunesVersion, detail: $detail)';
}

/// Result of `apple-support --download`: a verified installer waiting on disk.
///
/// The engine only reports one after Windows confirmed Apple signed it, so a
/// non-null [path] is the app's licence to run the file.
class ItunesDownload {
  /// Creates a download outcome.
  const ItunesDownload({
    this.path,
    this.bytes = 0,
    this.signer,
    this.signatureStatus,
  });

  /// Parses an `apple-support --download` payload.
  factory ItunesDownload.fromJson(Map<String, dynamic> json) => ItunesDownload(
        path: jsonString(json, 'path'),
        bytes: jsonInt(json, 'bytes'),
        signer: jsonString(json, 'signer'),
        signatureStatus: jsonString(json, 'signature_status'),
      );

  /// Where the verified installer is; null only from an unusable payload.
  final String? path;

  /// Its size on disk.
  final int bytes;

  /// The Authenticode subject Windows named, e.g. `CN=Apple Inc., O=Apple Inc., …`.
  final String? signer;

  /// Windows' verdict on the signature, which is always `Valid` here — anything
  /// else made the engine delete the file and raise instead.
  final String? signatureStatus;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ItunesDownload &&
          other.path == path &&
          other.bytes == bytes &&
          other.signer == signer &&
          other.signatureStatus == signatureStatus;

  @override
  int get hashCode => Object.hash(path, bytes, signer, signatureStatus);

  @override
  String toString() => 'ItunesDownload(path: $path, bytes: $bytes, '
      'signer: $signer, signatureStatus: $signatureStatus)';
}

/// Result of `apple-support --start-service`.
///
/// Declining the elevation prompt is a normal outcome, not a failure: [started]
/// is false, [wasDeclined] is true, and nothing was changed.
class AppleServiceStart {
  /// Creates a service-start outcome.
  const AppleServiceStart({
    this.started = false,
    this.reason,
    this.detail,
    this.status,
  });

  /// Parses an `apple-support --start-service` payload.
  factory AppleServiceStart.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? status = asJsonObject(json['status']);
    return AppleServiceStart(
      started: jsonBool(json, 'started'),
      reason: jsonString(json, 'reason'),
      detail: jsonString(json, 'detail'),
      status: status == null ? null : AppleSupportStatus.fromJson(status),
    );
  }

  /// The user declined the elevation prompt.
  static const String elevationDeclined = 'elevation_declined';

  /// Whether the service is running now.
  final bool started;

  /// `already_running`, `started`, `elevation_declined`, `did_not_start`, `failed`.
  final String? reason;

  /// One sentence describing the outcome, written to be shown verbatim.
  final String? detail;

  /// The status the engine re-read afterwards, so a caller never has to guess
  /// whether what it is showing survived the attempt.
  final AppleSupportStatus? status;

  bool get wasDeclined => reason == elevationDeclined;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppleServiceStart &&
          other.started == started &&
          other.reason == reason &&
          other.detail == detail &&
          other.status == status;

  @override
  int get hashCode => Object.hash(started, reason, detail, status);

  @override
  String toString() => 'AppleServiceStart(started: $started, reason: $reason, '
      'detail: $detail, status: $status)';
}

/// Result of `version`.
class EngineVersion {
  /// Creates an engine version.
  const EngineVersion({this.version});

  /// Parses a `version` payload.
  factory EngineVersion.fromJson(Map<String, dynamic> json) =>
      EngineVersion(version: jsonString(json, 'version'));

  /// The engine package version.
  final String? version;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is EngineVersion && other.version == version;

  @override
  int get hashCode => version.hashCode;

  @override
  String toString() => 'EngineVersion(version: $version)';
}

/// User-chosen sideload options.
///
/// Defaults mirror the web UI: extensions and device restrictions are removed,
/// file sharing is off, weak references are off. The signed-IPA pair defaults to
/// the engine's own behaviour, which is to delete the signed file it just
/// installed.
class SideloadOptions {
  /// Creates an option set, defaulting to the free-account-friendly choices.
  const SideloadOptions({
    this.udid,
    this.connection,
    this.bundleId,
    this.name,
    this.removeExtensions = true,
    this.removeDeviceRestrictions = true,
    this.enableFileSharing = false,
    this.weakDylibs = false,
    this.keepSigned = false,
    this.signedDirectory,
    this.dylibs = const <String>[],
  });

  /// The device to install to. Null leaves the choice to the engine, which
  /// refuses to guess when more than one device is connected.
  final String? udid;

  /// Transport to reach it by: `usb`, `wifi`, or null/`auto` to prefer USB and
  /// fall back. A forced transport is honoured rather than retried on the other.
  final String? connection;

  /// Override bundle identifier; blank or whitespace means automatic.
  final String? bundleId;

  /// Override display name; blank or whitespace keeps the app's own.
  final String? name;

  /// Remove app extensions and any watch app (a free-account requirement).
  final bool removeExtensions;

  /// Remove `UISupportedDevices` restrictions.
  final bool removeDeviceRestrictions;

  /// Enable Files app / iTunes file sharing.
  final bool enableFileSharing;

  /// Inject dylibs as `LC_LOAD_WEAK_DYLIB`; only meaningful with [dylibs].
  final bool weakDylibs;

  /// Keep the signed `.ipa` after installing instead of deleting it.
  final bool keepSigned;

  /// Where a kept `.ipa` is written; null (or blank) uses the engine's own
  /// default directory. Only meaningful with [keepSigned].
  final String? signedDirectory;

  /// Resolved dylib paths to inject. Read-only.
  final List<String> dylibs;

  /// Returns a copy with the given fields replaced.
  ///
  /// Passing null for [udid], [bundleId], [name] or [signedDirectory] keeps the
  /// current value; pass an empty string to clear one (blank and null behave
  /// identically in argv).
  SideloadOptions copyWith({
    String? udid,
    String? connection,
    String? bundleId,
    String? name,
    bool? removeExtensions,
    bool? removeDeviceRestrictions,
    bool? enableFileSharing,
    bool? weakDylibs,
    bool? keepSigned,
    String? signedDirectory,
    List<String>? dylibs,
  }) =>
      SideloadOptions(
        udid: udid ?? this.udid,
        connection: connection ?? this.connection,
        bundleId: bundleId ?? this.bundleId,
        name: name ?? this.name,
        removeExtensions: removeExtensions ?? this.removeExtensions,
        removeDeviceRestrictions:
            removeDeviceRestrictions ?? this.removeDeviceRestrictions,
        enableFileSharing: enableFileSharing ?? this.enableFileSharing,
        weakDylibs: weakDylibs ?? this.weakDylibs,
        keepSigned: keepSigned ?? this.keepSigned,
        signedDirectory: signedDirectory ?? this.signedDirectory,
        dylibs: dylibs ?? this.dylibs,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SideloadOptions &&
          other.udid == udid &&
          other.connection == connection &&
          other.bundleId == bundleId &&
          other.name == name &&
          other.removeExtensions == removeExtensions &&
          other.removeDeviceRestrictions == removeDeviceRestrictions &&
          other.enableFileSharing == enableFileSharing &&
          other.weakDylibs == weakDylibs &&
          other.keepSigned == keepSigned &&
          other.signedDirectory == signedDirectory &&
          _listEquals(other.dylibs, dylibs);

  @override
  int get hashCode => Object.hash(
        udid,
        connection,
        bundleId,
        name,
        removeExtensions,
        removeDeviceRestrictions,
        enableFileSharing,
        weakDylibs,
        keepSigned,
        signedDirectory,
        Object.hashAll(dylibs),
      );

  @override
  String toString() => 'SideloadOptions(udid: $udid, '
      'connection: $connection, '
      'bundleId: $bundleId, name: $name, '
      'removeExtensions: $removeExtensions, '
      'removeDeviceRestrictions: $removeDeviceRestrictions, '
      'enableFileSharing: $enableFileSharing, weakDylibs: $weakDylibs, '
      'keepSigned: $keepSigned, signedDirectory: $signedDirectory, '
      'dylibs: $dylibs)';
}

/// A parsed sideload progress event.
///
/// [percent] is null for the indeterminate provision/sign phases and a
/// monotonic 0-100 value during install (the engine computes it, including the
/// pinned final 100).
class SideloadProgress {
  /// Creates a progress event.
  const SideloadProgress({this.phase, this.percent, this.step, this.bundleId});

  /// `provision`, `sign`, `install`, ...
  final String? phase;

  /// 0-100 during install; null while indeterminate.
  final double? percent;

  /// The user-facing step label, e.g. `Contacting Apple...`.
  final String? step;

  /// The app being sideloaded, once known.
  final String? bundleId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SideloadProgress &&
          other.phase == phase &&
          other.percent == percent &&
          other.step == step &&
          other.bundleId == bundleId;

  @override
  int get hashCode => Object.hash(phase, percent, step, bundleId);

  @override
  String toString() => 'SideloadProgress(phase: $phase, percent: $percent, '
      'step: $step, bundleId: $bundleId)';
}

// Base64 icons are hundreds of kilobytes; never let one into a log line.
String _describeIcon(String? icon) =>
    icon == null ? 'null' : '${icon.length} chars';

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
