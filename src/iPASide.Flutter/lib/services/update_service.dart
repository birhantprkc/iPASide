import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../platform/app_paths.dart';
import 'update_planner.dart';

/// The result of one update check.
@immutable
class UpdateCheck {
  const UpdateCheck(this.outcome, {this.latestVersion, this.pending, this.detail});

  final UpdateOutcome outcome;

  /// The newest published version, when one was found.
  final String? latestVersion;

  /// The verified installer waiting on disk, when [outcome] is
  /// [UpdateOutcome.readyToInstall].
  final PendingUpdate? pending;

  /// Extra context for the UI or the log (an error message, usually).
  final String? detail;
}

/// Checks GitHub for a newer iPASide, downloads it, and verifies it before
/// offering it to the user.
///
/// Deliberately fail-closed, in the same order as every step below:
///   1. the release must advertise a newer version and an installer asset;
///   2. it must publish `SHA256SUMS.txt` — absent means refuse, never "assume good";
///   3. the download's SHA-256 must match the published checksum *for its filename*.
///
/// The verified installer is then **staged for a one-click install**, never run
/// automatically. A checksum published in the same release as the installer
/// proves integrity, not authenticity: whoever could swap the installer could
/// swap the sums too. Only a code signature would settle that, and iPASide's
/// releases are not signed, so the user always consents to the install. If
/// signing is added later, an Authenticode check is the missing gate that would
/// make an unattended install defensible.
class UpdateService {
  UpdateService({
    required this.currentVersion,
    AppPaths? paths,
    this.owner = 'pwnapplehat',
    this.repo = 'iPASide',
    HttpClient? httpClient,
    void Function(String message)? log,
  })  : _paths = paths ?? AppPaths.instance,
        _http = httpClient ?? HttpClient(),
        _log = log ?? _defaultLog;

  final String currentVersion;
  final String owner;
  final String repo;

  final AppPaths _paths;
  final HttpClient _http;
  final void Function(String) _log;

  static void _defaultLog(String message) => debugPrint('[update] $message');

  Uri get _latestReleaseApi =>
      Uri.https('api.github.com', '/repos/$owner/$repo/releases/latest');

  /// Where the app's own release page lives, for a "see what's new" link.
  Uri get releasesPage => Uri.https('github.com', '/$owner/$repo/releases');

  String get _stagingDir => '${_paths.root}${Platform.pathSeparator}updates';

  /// Compares versions only — no download.
  ///
  /// This is what runs at startup: one small API call, so a new release is
  /// noticed without spending ~100 MB of someone's connection uninvited.
  Future<UpdateCheck> peekLatest() async {
    final running = AppVersion.tryParse(currentVersion);
    if (running == null) {
      return const UpdateCheck(
        UpdateOutcome.error,
        detail: 'The running version could not be read.',
      );
    }

    try {
      final json = await _getString(_latestReleaseApi);
      if (json == null) {
        return const UpdateCheck(
          UpdateOutcome.error,
          detail: 'Could not reach GitHub to check for updates.',
        );
      }

      final release = UpdatePlanner.parseRelease(json, arch: _architecture);
      final latest = AppVersion.tryParse(release.tag);
      if (latest == null || latest <= running) {
        _clearStaged();
        return UpdateCheck(UpdateOutcome.upToDate, latestVersion: latest?.toString());
      }
      return UpdateCheck(UpdateOutcome.updateAvailable, latestVersion: latest.toString());
    } on Object catch (error) {
      _log('peek failed: $error');
      return const UpdateCheck(
        UpdateOutcome.error,
        detail: 'The update check could not finish.',
      );
    }
  }

  /// Downloads the newest release, verifies it, and stages it for installation.
  Future<UpdateCheck> downloadUpdate({void Function(double progress)? onProgress}) async {
    final running = AppVersion.tryParse(currentVersion);
    if (running == null) {
      return const UpdateCheck(
        UpdateOutcome.error,
        detail: 'The running version could not be read.',
      );
    }

    try {
      final json = await _getString(_latestReleaseApi);
      if (json == null) {
        return const UpdateCheck(
          UpdateOutcome.error,
          detail: 'Could not reach GitHub to check for updates.',
        );
      }

      final release = UpdatePlanner.parseRelease(json, arch: _architecture);
      final latest = AppVersion.tryParse(release.tag);

      if (latest == null || latest <= running) {
        // A previous run may have staged a build for a release that has since
        // been pulled; drop it so the app cannot keep offering a ghost update.
        _clearStaged();
        return UpdateCheck(UpdateOutcome.upToDate, latestVersion: latest?.toString());
      }

      _log('update available: $latest (running $running)');

      if (release.setupUrl == null || release.setupName == null) {
        return UpdateCheck(
          UpdateOutcome.noSetupAsset,
          latestVersion: latest.toString(),
          detail: 'That release has no installer to download.',
        );
      }
      if (release.sumsUrl == null) {
        _log('refused: release publishes no SHA256SUMS.txt');
        return UpdateCheck(
          UpdateOutcome.noChecksums,
          latestVersion: latest.toString(),
          detail: 'That release publishes no checksums, so it cannot be verified.',
        );
      }

      final directory = Directory(_stagingDir);
      await directory.create(recursive: true);
      final setupPath =
          '$_stagingDir${Platform.pathSeparator}${release.setupName}';

      await _download(Uri.parse(release.setupUrl!), setupPath, onProgress: onProgress);

      final sums = await _getString(Uri.parse(release.sumsUrl!));
      final actual = await _sha256Hex(setupPath);
      if (sums == null ||
          !UpdatePlanner.checksumMatches(sums, release.setupName!, actual)) {
        _log('refused: checksum mismatch for ${release.setupName}');
        await _tryDelete(setupPath);
        return UpdateCheck(
          UpdateOutcome.checksumMismatch,
          latestVersion: latest.toString(),
          detail: 'The download did not match its published checksum, so it was discarded.',
        );
      }

      await _clearStagedExcept(setupPath);
      final size = await File(setupPath).length();
      _log('staged ${release.setupName} (verified) for one-click install');

      return UpdateCheck(
        UpdateOutcome.readyToInstall,
        latestVersion: latest.toString(),
        pending: PendingUpdate(
          version: latest.toString(),
          setupPath: setupPath,
          sizeBytes: size,
        ),
      );
    } on Object catch (error) {
      _log('check failed: $error');
      return UpdateCheck(
        UpdateOutcome.error,
        detail: 'The update check could not finish.',
      );
    }
  }

  /// Runs a staged installer. Inno Setup upgrades in place and restarts the app,
  /// so the running copy does not have to tear itself down first.
  Future<bool> installStaged(PendingUpdate update) async {
    if (!File(update.setupPath).existsSync()) return false;
    try {
      await Process.start(
        update.setupPath,
        const <String>[],
        mode: ProcessStartMode.detached,
        runInShell: true,
      );
      return true;
    } on Object catch (error) {
      _log('failed to launch the installer: $error');
      return false;
    }
  }

  String get _architecture {
    final arch = Platform.environment['PROCESSOR_ARCHITECTURE']?.toLowerCase();
    return arch != null && arch.contains('arm') ? 'arm64' : 'x64';
  }

  Future<String?> _getString(Uri uri) async {
    final request = await _http.getUrl(uri);
    _applyHeaders(request);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      _log('GET $uri -> ${response.statusCode}');
      await response.drain<void>();
      return null;
    }
    return response.transform(utf8.decoder).join();
  }

  Future<void> _download(
    Uri uri,
    String destination, {
    void Function(double progress)? onProgress,
  }) async {
    final request = await _http.getUrl(uri);
    _applyHeaders(request);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('download failed (${response.statusCode})', uri: uri);
    }

    final total = response.contentLength;
    final sink = File(destination).openWrite();
    var received = 0;
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  void _applyHeaders(HttpClientRequest request) {
    // GitHub's API rejects requests without a User-Agent.
    request.headers.set(HttpHeaders.userAgentHeader,
        'iPASide/$currentVersion (+https://github.com/$owner/$repo)');
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
  }

  /// Streams the file through SHA-256 rather than reading ~100 MB into memory.
  Future<String> _sha256Hex(String path) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    await for (final chunk in File(path).openRead()) {
      input.add(chunk);
    }
    input.close();
    return sink.value.toString();
  }

  void _clearStaged() {
    final directory = Directory(_stagingDir);
    if (!directory.existsSync()) return;
    for (final entry in directory.listSync()) {
      if (entry is File) {
        try {
          entry.deleteSync();
        } on Object {
          // Best effort; a locked file just gets replaced next time.
        }
      }
    }
  }

  Future<void> _clearStagedExcept(String keepPath) async {
    final directory = Directory(_stagingDir);
    if (!directory.existsSync()) return;
    for (final entry in directory.listSync()) {
      if (entry is File && entry.path != keepPath) {
        await _tryDelete(entry.path);
      }
    }
  }

  Future<void> _tryDelete(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } on Object {
      // Best effort.
    }
  }
}

/// Collects the single digest that `startChunkedConversion` emits, so hashing can
/// stream without pulling in `package:convert` for its AccumulatorSink.
class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
