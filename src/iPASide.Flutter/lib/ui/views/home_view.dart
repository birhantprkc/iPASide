import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../engine/engine.dart';
import '../../services/file_picker.dart';
import '../../viewmodels/account_selection.dart';
import '../../viewmodels/apple_support_view_model.dart';
import '../../viewmodels/device_selection.dart';
import '../../viewmodels/home_view_model.dart';
import '../../viewmodels/navigation_state.dart';
import '../shell/app_dialogs.dart';
import '../shell/logo_mark.dart';
import '../theme/app_theme.dart';
import '../widgets/apple_support_banner.dart';
import '../widgets/buttons.dart';
import '../widgets/motion.dart';
import '../widgets/progress.dart';
import '../widgets/smooth_scroll.dart';
import '../widgets/surfaces.dart';

/// Home: hero, status cards, pairing file, quick actions.
class HomeView extends StatelessWidget {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (ctx) => HomeViewModel(
          engine: ctx.read<EngineApi>(),
          navigation: ctx.read<NavigationState>(),
          devices: ctx.read<DeviceSelection>(),
          picker: ctx.read<FilePickerService>(),
          dialogs: ctx.read<DialogService>(),
        ),
        child: const _HomeBody(),
      );
}

class _HomeBody extends StatelessWidget {
  const _HomeBody();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<HomeViewModel>();
    // Watched here rather than reached for inside the cards, so one notification
    // repaints the banner and the two cards whose text it changes together.
    final apple = context.watch<AppleSupportViewModel>();

    return SmoothScrollView(
      padding: const EdgeInsets.fromLTRB(Space.s6, Space.s5, Space.s6, Space.s7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Above the hero on purpose. Without Apple's device service nothing on
          // this screen can do anything, so it outranks the invitation to sideload.
          if (apple.hasNotice) ...[
            Entrance(child: AppleSupportBanner(model: apple)),
            const SizedBox(height: Space.s5),
          ],
          Entrance(child: _Hero(onSideload: vm.openSideload)),
          const SizedBox(height: Space.s6),
          const Entrance(index: 1, child: SectionLabel('STATUS')),
          const SizedBox(height: Space.s3),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Entrance(index: 2, child: _DeviceCard(vm: vm, apple: apple)),
                ),
                const SizedBox(width: Space.s4),
                Expanded(child: Entrance(index: 3, child: _AppleIdCard(vm: vm))),
                const SizedBox(width: Space.s4),
                Expanded(
                  child: Entrance(index: 4, child: _ConnectionCard(vm: vm, apple: apple)),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.s6),
          const Entrance(index: 5, child: SectionLabel('PAIRING FILE')),
          const SizedBox(height: Space.s3),
          Entrance(index: 6, child: _PairingCard(vm: vm)),
          const SizedBox(height: Space.s6),
          const Entrance(index: 7, child: SectionLabel('QUICK ACTIONS')),
          const SizedBox(height: Space.s3),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Entrance(
                    index: 8,
                    child: ActionTile(
                      icon: Icons.collections_bookmark_outlined,
                      title: 'Library',
                      subtitle: 'Your sideloaded apps and how long until each expires.',
                      onTap: vm.openLibrary,
                    ),
                  ),
                ),
                const SizedBox(width: Space.s4),
                Expanded(
                  child: Entrance(
                    index: 9,
                    child: ActionTile(
                      icon: Icons.grid_view_rounded,
                      title: 'Apps',
                      subtitle: 'Everything installed on your iPhone, with uninstall.',
                      onTap: vm.openApps,
                    ),
                  ),
                ),
                const SizedBox(width: Space.s4),
                Expanded(
                  child: Entrance(
                    index: 10,
                    child: ActionTile(
                      icon: Icons.monitor_heart_outlined,
                      title: 'Diagnostics',
                      subtitle: 'Check the toolchain, Apple services, and anisette.',
                      onTap: vm.openDiagnostics,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.onSideload});

  final VoidCallback onSideload;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(Space.s7),
      decoration: BoxDecoration(
        gradient: p.heroGradient,
        borderRadius: Radii.rLarge,
        border: Border.all(color: p.cardBorder),
        boxShadow: p.cardShadow,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Sideload apps to your iPhone', style: context.t.display),
                const SizedBox(height: Space.s2 + 2),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Text(
                    'Sign any .ipa with your free Apple ID and install it over USB or '
                    'Wi-Fi \u2014 no jailbreak. iPASide auto-refreshes it before the '
                    '7-day profile expires.',
                    style: context.t.bodyMuted,
                  ),
                ),
                const SizedBox(height: Space.s5),
                AppButton(
                  label: 'Sideload an app',
                  icon: Icons.inventory_2_outlined,
                  tone: ButtonTone.primary,
                  onPressed: onSideload,
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.s6),
          const LogoMark(size: 96),
        ],
      ),
    );
  }
}

/// DEVICE: the lockdown identity of the phone iPASide is targeting.
///
/// The only one of the three with no footer: four label/value rows are all
/// substance, and it is what sets the row's height.
class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.vm, required this.apple});

  final HomeViewModel vm;
  final AppleSupportViewModel apple;

  @override
  Widget build(BuildContext context) => StatusCard(
        label: 'DEVICE',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (vm.isDeviceLoading)
              const LoadingLine(label: 'Reading device\u2026')
            // Ahead of both the error and the empty state, because it explains
            // them. Without Apple's service the device call fails with whatever
            // usbmux said, and the empty state tells the user to plug in a cable
            // that was never the problem — so when this is the reason, it is the
            // only thing worth saying.
            else if (apple.deviceBlockedMessage case final String reason)
              Text(reason, style: context.t.bodyMuted)
            else if (vm.hasDeviceError)
              Text(vm.deviceError!, style: context.t.bodyMuted)
            else if (vm.isDeviceEmpty)
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(
                      text: 'No device connected. Plug in your iPhone over USB, '
                          'unlock it, and tap ',
                    ),
                    TextSpan(
                      text: 'Trust',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: context.palette.textPrimary,
                      ),
                    ),
                    const TextSpan(text: '.'),
                  ],
                ),
                style: context.t.bodyMuted,
              )
            else ...[
              KeyValueRow('Name', vm.deviceName),
              KeyValueRow('Model', vm.deviceModel),
              KeyValueRow('iOS', vm.deviceIos),
              KeyValueRow('UDID', vm.deviceUdid, mono: true),
            ],
          ],
        ),
      );
}

/// APPLE ID: which account signs the apps, and the way out of it.
///
/// The email is the card's headline on its own line rather than the value half of
/// a label/value row, because in a row it has to share the width with its label
/// and gets ellipsised — and a truncated email answers nothing. Stacked it has
/// the whole card to use, and wraps rather than truncating if it still runs out.
///
/// The `connected` pill that used to sit here has moved to CONNECTION. Next to a
/// card about exactly what is connected, a green pill under the email invited the
/// reading "your Apple ID is connected", which is not a thing.
class _AppleIdCard extends StatelessWidget {
  const _AppleIdCard({required this.vm});

  final HomeViewModel vm;

  @override
  Widget build(BuildContext context) {
    if (vm.isAccountLoading) {
      return const StatusCard(
        label: 'APPLE ID',
        child: LoadingLine(label: 'Checking session\u2026'),
      );
    }
    if (vm.hasAccountError) {
      return StatusCard(
        label: 'APPLE ID',
        child: Text(vm.accountError!, style: context.t.bodyMuted),
      );
    }

    if (vm.isAuthenticated) {
      final AccountSelection accounts = context.watch<AccountSelection>();
      return StatusCard(
        label: 'APPLE ID',
        footer: Row(
          children: [
            AppButton(
              label: 'Sign out',
              compact: true,
              onPressed: vm.signOut,
            ),
            // Only offered once there is a second account: a menu that can only
            // pick what is already picked is a menu asking the user to do nothing.
            if (accounts.hasChoice) ...[
              const SizedBox(width: Space.s2),
              _AccountSwitcher(accounts: accounts),
            ],
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              accounts.hasChoice
                  ? 'Signing with ${accounts.accounts.length} accounts'
                  : 'Signed in',
              style: context.t.smallMuted,
            ),
            const SizedBox(height: Space.s1),
            Text(
              vm.accountEmail,
              style: context.t.semi(FontSizes.body),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      );
    }

    return StatusCard(
      label: 'APPLE ID',
      footer: AppButton(
        label: 'Sign in',
        tone: ButtonTone.primary,
        compact: true,
        onPressed: vm.signIn,
      ),
      child: Text('Not signed in yet.', style: context.t.bodyMuted),
    );
  }
}

/// Picks which signed-in Apple ID new sideloads use.
///
/// Switching is safe for apps already on the phone: a refresh re-signs under the
/// account that provisions for the team which signed it, not whichever is chosen
/// here, because a different team's identity cannot install over an existing copy.
class _AccountSwitcher extends StatelessWidget {
  const _AccountSwitcher({required this.accounts});

  final AccountSelection accounts;

  @override
  Widget build(BuildContext context) {
    final String? active = accounts.activeEmail;
    return PopupMenuButton<String>(
      tooltip: 'Switch Apple ID',
      position: PopupMenuPosition.under,
      enabled: accounts.busyEmail == null,
      onSelected: accounts.use,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        for (final AppleAccount account in accounts.accounts)
          PopupMenuItem<String>(
            value: account.email,
            child: Row(
              children: [
                Icon(
                  account.email == active
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: account.email == active
                      ? context.palette.accent
                      : context.palette.textMuted,
                ),
                const SizedBox(width: Space.s2),
                Flexible(
                  child: Text(
                    account.email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: AppButton(
        label: 'Switch',
        compact: true,
        onPressed: null,
      ),
    );
  }
}

/// CONNECTION: how the targeted phone is reachable.
///
/// Carries the `connected` pill as its verdict, which is the card the pill was
/// always describing. When Apple's device service is down it carries the reason
/// instead: this card used to report "USB — " and "No device visible over USB or
/// Wi-Fi" without ever saying that Windows had no way to look.
class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.vm, required this.apple});

  final HomeViewModel vm;
  final AppleSupportViewModel apple;

  @override
  Widget build(BuildContext context) {
    final String? blocked = apple.usbBlockedReason;
    return StatusCard(
      label: 'CONNECTION',
      footer: blocked != null
          ? const Pill(
              label: 'USB unavailable',
              kind: PillKind.danger,
              icon: Icons.usb_off_rounded,
            )
          : vm.hasVisibleDevice
              ? const Pill(
                  label: 'connected',
                  kind: PillKind.ok,
                  icon: Icons.check_rounded,
                )
              : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (vm.isConnectionLoading)
            const LoadingLine(label: 'Scanning\u2026')
          else if (blocked != null)
            Text(blocked, style: context.t.bodyMuted)
          else if (vm.hasConnectionError)
            Text(vm.connectionError!, style: context.t.bodyMuted)
          else if (vm.isConnectionEmpty)
            Text('No device visible over USB or Wi-Fi.', style: context.t.bodyMuted)
          else ...[
            _LinkRow(icon: Icons.usb_rounded, label: 'USB', value: vm.usbText),
            _LinkRow(icon: Icons.wifi_rounded, label: 'Wi-Fi', value: vm.wifiText),
          ],
        ],
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        // The same rhythm KeyValueRow uses, so the CONNECTION lines sit at the
        // same heights as the DEVICE lines beside them.
        padding: Pad.statusRow,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(icon, size: Sizes.icon, color: context.palette.textMuted),
                const SizedBox(width: Space.s2),
                Text(label, style: context.t.smallMuted),
              ],
            ),
            Text(value, style: context.t.small),
          ],
        ),
      );
}

/// PAIRING FILE: this PC's record for the selected phone, and the apps that need it.
///
/// Full width under STATUS rather than a fourth column: three status cards are
/// already a row, and pairing has a paragraph of explanation plus three actions
/// that would not fit in a column without truncating the sentence that makes
/// the card honest about iOS 26.
class _PairingCard extends StatelessWidget {
  const _PairingCard({required this.vm});

  final HomeViewModel vm;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'A pairing file is this PC\u2019s trusted identity with your iPhone. '
            'SideStore, AltStore, LiveContainer, EscapeOS, and StikDebug each look '
            'for it in their Documents folder. iPASide can export it, import an '
            'iLoader file that includes Remote Pairing keys, and place it in every '
            'supported app that is installed.',
            style: context.t.bodyMuted,
          ),
          const SizedBox(height: Space.s4),
          ..._body(context),
          const SizedBox(height: Space.s5),
          Wrap(
            spacing: Space.s2,
            runSpacing: Space.s2,
            children: [
              AppButton(
                label: 'Import',
                icon: Icons.file_open_outlined,
                compact: true,
                busy: vm.isPairingBusy,
                onPressed: vm.canImportPairing ? vm.importPairing : null,
              ),
              AppButton(
                label: 'Export',
                icon: Icons.save_alt_outlined,
                compact: true,
                busy: vm.isPairingBusy,
                onPressed: vm.canExportPairing ? vm.exportPairing : null,
              ),
              AppButton(
                label: 'Place on device',
                icon: Icons.phonelink_setup_outlined,
                tone: ButtonTone.primary,
                compact: true,
                busy: vm.isPairingBusy,
                onPressed: vm.canPlacePairing ? vm.placePairing : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    if (vm.isPairingLoading) {
      return const <Widget>[LoadingLine(label: 'Reading pairing file\u2026')];
    }
    if (vm.hasPairingError) {
      return <Widget>[Text(vm.pairingError!, style: context.t.bodyMuted)];
    }
    final PairingStatus? status = vm.pairing;
    if (status == null) {
      return <Widget>[
        Text(
          'Connect an iPhone to manage its pairing file.',
          style: context.t.bodyMuted,
        ),
      ];
    }

    return <Widget>[
      Wrap(
        spacing: Space.s2,
        runSpacing: Space.s2,
        children: [
          Pill(
            label: status.hasLockdown ? 'USB pairing' : 'No USB pairing',
            kind: status.hasLockdown ? PillKind.ok : PillKind.danger,
            icon: status.hasLockdown
                ? Icons.check_rounded
                : Icons.close_rounded,
          ),
          Pill(
            label: status.hasRppairing
                ? 'Remote Pairing'
                : 'No Remote Pairing',
            kind: status.hasRppairing ? PillKind.ok : PillKind.warn,
            icon: status.hasRppairing
                ? Icons.check_rounded
                : Icons.warning_amber_rounded,
          ),
          if (status.imported)
            const Pill(
              label: 'Imported',
              kind: PillKind.ok,
              icon: Icons.file_download_outlined,
            ),
        ],
      ),
      const SizedBox(height: Space.s3),
      if (status.note != null)
        Text(status.note!, style: context.t.bodyMuted)
      else if (status.error != null)
        Text(status.error!, style: context.t.bodyMuted),
      const SizedBox(height: Space.s3),
      Text(_consumerLine(status), style: context.t.smallMuted),
    ];
  }

  static String _consumerLine(PairingStatus status) {
    if (!status.deviceReachable) {
      final String reason = status.deviceError ?? 'the device could not be listed';
      return 'Installed apps were not listed ($reason).';
    }
    if (status.consumers.isEmpty) {
      return 'No supported apps are installed. Sideload EscapeOS, SideStore, '
          'AltStore, LiveContainer, or StikDebug, then place the file.';
    }
    final String names = status.consumers
        .map((PairingConsumerInfo c) => c.label)
        .join(', ');
    return '${status.consumers.length} supported app${status.consumers.length == 1 ? '' : 's'} '
        'installed: $names.';
  }
}
