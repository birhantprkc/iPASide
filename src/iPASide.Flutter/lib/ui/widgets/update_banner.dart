import 'package:flutter/material.dart';

import '../../viewmodels/update_view_model.dart';
import '../theme/app_theme.dart';
import 'buttons.dart';
import 'progress.dart';
import 'surfaces.dart';

/// BitBroom-style update notice under the title bar.
///
/// Same Download / Install actions as Settings → Updates; See Changes opens the
/// release page, Later hides the banner for this version. Listens to [model]
/// itself so progress and Install/Download swaps repaint even when a parent is
/// not also watching the view model.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.model});

  final UpdateViewModel model;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: model,
        builder: (BuildContext context, Widget? _) => _BannerBody(model: model),
      );
}

class _BannerBody extends StatelessWidget {
  const _BannerBody({required this.model});

  final UpdateViewModel model;

  @override
  Widget build(BuildContext context) {
    final String? version = model.latestVersion;
    final String body = model.isDownloading
        ? 'Downloading${version == null ? '' : ' $version'}\u2026'
        : model.canInstall
            ? 'Version $version is downloaded and verified.'
            : 'Version $version is available.';

    return Alert(
      kind: AlertKind.info,
      title: model.canInstall ? 'Update ready' : 'Update available',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(body, style: context.t.small),
          if (model.isDownloading) ...<Widget>[
            const SizedBox(height: Space.s3),
            AppProgressBar(value: model.progress * 100),
          ],
          const SizedBox(height: Space.s4),
          Wrap(
            spacing: Space.s2,
            runSpacing: Space.s2,
            children: <Widget>[
              AppButton(
                label: 'See Changes',
                compact: true,
                onPressed: model.seeChanges,
              ),
              if (model.canInstall)
                AppButton(
                  label: 'Install now',
                  icon: Icons.download_rounded,
                  tone: ButtonTone.primary,
                  compact: true,
                  onPressed: model.install,
                )
              else if (!model.hasLaunchedInstaller)
                AppButton(
                  label: version == null ? 'Download' : 'Download $version',
                  icon: Icons.download_rounded,
                  tone: ButtonTone.primary,
                  compact: true,
                  busy: model.isDownloading,
                  onPressed: model.canDownload ? model.download : null,
                ),
              AppButton(
                label: 'Later',
                compact: true,
                onPressed: model.isDownloading ? null : model.dismissBanner,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
