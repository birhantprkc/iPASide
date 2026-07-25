import 'dart:io';

import '../platform/windows_file_dialog.dart';

/// Native file dialogs for the things the app opens.
///
/// Abstracted so view models can be exercised without a desktop shell.
abstract class FilePickerService {
  /// Single `.ipa`; null when cancelled.
  Future<String?> pickIpa();

  /// One or more `.deb` / `.dylib` tweaks; empty when cancelled.
  Future<List<String>> pickTweaks();

  /// The folder to keep signed IPAs in; null when cancelled.
  Future<String?> pickSignedFolder();
}

/// Shell-backed implementation.
///
/// On Windows this is `IFileOpenDialog` driven directly, which is what restores
/// the titles the previous build had. Everywhere else there is no dialog yet, so
/// every call reports a cancelled pick and a port only has to add its branch
/// here.
class NativeFilePickerService implements FilePickerService {
  const NativeFilePickerService();

  /// Titles carried over verbatim from the previous build.
  static const String ipaTitle = 'Choose an app to sideload';

  /// Title of the multi-select tweak dialog.
  static const String tweaksTitle = 'Add tweaks';

  /// Title of the folder dialog behind the Signed IPAs setting.
  static const String signedFolderTitle = 'Choose where to keep signed IPAs';

  /// Type dropdown for the IPA dialog.
  static const List<FileDialogFilter> ipaFilters = <FileDialogFilter>[
    FileDialogFilter(label: 'iOS app (*.ipa)', spec: '*.ipa'),
    FileDialogFilter.allFiles,
  ];

  /// Type dropdown for the tweak dialog. The engine resolves a `.deb` down to
  /// the dylibs inside it, so both extensions belong in one entry.
  static const List<FileDialogFilter> tweakFilters = <FileDialogFilter>[
    FileDialogFilter(label: 'Tweaks (*.deb;*.dylib)', spec: '*.deb;*.dylib'),
    FileDialogFilter.allFiles,
  ];

  @override
  Future<String?> pickIpa() async {
    if (!Platform.isWindows) return null;
    await _letTheTapPaint();

    final List<String> chosen = WindowsFileDialog.open(
      title: ipaTitle,
      filters: ipaFilters,
    );
    return chosen.isEmpty ? null : chosen.first;
  }

  @override
  Future<List<String>> pickTweaks() async {
    if (!Platform.isWindows) return const <String>[];
    await _letTheTapPaint();

    return WindowsFileDialog.open(
      title: tweaksTitle,
      filters: tweakFilters,
      allowMultiple: true,
    );
  }

  @override
  Future<String?> pickSignedFolder() async {
    if (!Platform.isWindows) return null;
    await _letTheTapPaint();

    return WindowsFileDialog.openFolder(title: signedFolderTitle);
  }

  /// Yields once before blocking.
  ///
  /// The dialog runs its own message loop, so no frame is produced while it is
  /// up; without this the button or dropzone that opened it would still be
  /// drawn un-pressed underneath.
  static Future<void> _letTheTapPaint() => Future<void>.delayed(Duration.zero);
}
