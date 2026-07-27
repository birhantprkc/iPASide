"""LiveContainer setup: sign it with what it needs, then hand it the certificate.

LiveContainer runs other apps inside itself, which is how it gets past the three-app
limit a free Apple ID imposes: the phone sees one installed app no matter how many are
loaded into it. To sign those guest apps on device it needs JIT-less mode, and JIT-less
mode needs two things that an ordinary sideload does not provide.

**Entitlements the profile does not spell out.** A free profile grants ``TEAMID.*`` for
keychain access, but LiveContainer looks for 128 explicit
``TEAMID.com.kdt.livecontainer.shared.N`` groups, plus a shared app group. The wildcard
legally covers the explicit entries, so signing with the expanded list is accepted -
which is what :func:`build_entitlements` produces, and why this needs a signing profile
rather than plain defaults. App groups also have to be attached to the App ID before the
provisioning profile is downloaded; :mod:`ipaside_engine.provision` handles that.

**Its own signing certificate.** LiveContainer reads the certificate from the app group's
``UserDefaults`` suite, and that container cannot be written from a PC: house_arrest's AFC
session lists directories through ``..`` but refuses to open or stat anything outside the
app's own container. Normally the user imports the ``.p12`` by hand through LiveContainer's
Settings. Instead we leave an import request in its ``Documents`` - which *is* writable,
because LiveContainer declares ``UIFileSharingEnabled`` - and inject a small dylib that
performs the import on first launch. See tools/lc-cert-import/.

If that dylib is not present in the build, everything still works; the certificate simply
has to be imported by hand, and :func:`setup` says so in its result.
"""

from __future__ import annotations

import asyncio
import plistlib
from pathlib import Path
from typing import Any, Callable

import requests

from . import apps, ipa as ipa_module, lockdown, provision, signing
from .errors import EngineError

#: LiveContainer's own identifier; the team id is appended for a free account.
BUNDLE_PREFIX = "com.kdt.livecontainer"

#: How many explicit keychain access groups LiveContainer expects. It derives guest-app
#: keychain groups by index, so a short list silently breaks apps that use the keychain.
KEYCHAIN_GROUPS = 128

#: LiveContainer looks for a store's app group and uses the first it can reach, so both
#: are provisioned and signed in - it decides which at runtime.
_GROUP_PREFIXES = (
    "group.com.SideStore.SideStore.",
    "group.com.rileytestut.AltStore.",
)

#: Where the release comes from, and the only place iPASide will download it from.
RELEASES_URL = "https://api.github.com/repos/LiveContainer/LiveContainer/releases/latest"
PROJECT_URL = "https://github.com/LiveContainer/LiveContainer"

#: Written into LiveContainer's Documents for the injected dylib to consume.
REQUEST_NAME = "iPASide-cert-import.plist"
CERTIFICATE_NAME = "iPASide-certificate.p12"

#: Name of the signing profile :mod:`ipaside_engine.sideload` resolves for LiveContainer.
SIGNING_PROFILE = "livecontainer"

_TIMEOUTS = (20, 60)
_CHUNK_BYTES = 1 << 20

# (phase, percent, step) - the same shape sideload reports, so a UI can render both.
ProgressFn = Callable[[str, Any, "str | None"], None]


class LiveContainerError(EngineError):
    """LiveContainer could not be set up."""


def bundle_id_for(team_id: str) -> str:
    """LiveContainer's team-scoped bundle id, which is what its app groups key off."""
    return f"{BUNDLE_PREFIX}.{team_id}"


def app_group_identifiers(team_id: str) -> list[str]:
    """The app groups LiveContainer looks for, in the order it prefers them."""
    return [f"{prefix}{team_id}" for prefix in _GROUP_PREFIXES]


def build_entitlements(team_id: str, bundle_id: str) -> dict[str, Any]:
    """LiveContainer's entitlements with the build variables resolved.

    Deliberately narrower than LiveContainer's own build entitlements: HealthKit and
    ``com.apple.developer.kernel.increased-memory-limit`` are omitted because a free
    profile does not grant them, and asking for an entitlement the profile lacks makes
    the whole signature invalid rather than partially granted. Everything JIT-less mode
    needs - identifier, ``get-task-allow``, app groups, keychain groups - is here.
    """
    prefix = f"{team_id}."
    return {
        "application-identifier": f"{team_id}.{bundle_id}",
        "com.apple.developer.team-identifier": team_id,
        "com.apple.security.application-groups": app_group_identifiers(team_id),
        "get-task-allow": True,
        "keychain-access-groups": (
            [f"{prefix}{BUNDLE_PREFIX}.shared"]
            + [f"{prefix}{BUNDLE_PREFIX}.shared.{n}" for n in range(1, KEYCHAIN_GROUPS)]
        ),
    }


def is_livecontainer(info: dict[str, Any]) -> bool:
    """Whether an inspected IPA is LiveContainer."""
    return str(info.get("bundle_id") or "").startswith(BUNDLE_PREFIX)


# --------------------------------------------------------------------------- #
# Getting hold of the IPA
# --------------------------------------------------------------------------- #
def latest_release() -> dict[str, Any]:
    """Describe LiveContainer's newest release, without downloading it."""
    try:
        response = requests.get(RELEASES_URL, timeout=_TIMEOUTS)
        response.raise_for_status()
        release = response.json()
    except (requests.RequestException, ValueError) as exc:
        raise LiveContainerError(
            "Could not reach GitHub to check for the latest LiveContainer release. "
            "Check your connection, or download the IPA yourself and pick it."
        ) from exc

    asset = _pick_asset(release.get("assets") or [])
    if asset is None:
        raise LiveContainerError(
            f"LiveContainer {release.get('tag_name') or 'latest'} has no .ipa attached. "
            f"Download it from {PROJECT_URL}/releases and pick the file."
        )
    return {
        "version": release.get("tag_name"),
        "name": release.get("name"),
        "published_at": release.get("published_at"),
        "notes_url": release.get("html_url"),
        "asset_name": asset.get("name"),
        "url": asset.get("browser_download_url"),
        "bytes": asset.get("size"),
    }


def _pick_asset(assets: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Choose the plain LiveContainer IPA from a release's assets.

    Releases carry several builds; the sideloading one is the unadorned ``.ipa``. Any
    asset naming a variant we cannot provision - notably the TrollStore/jailbreak builds,
    which expect entitlements a free profile will never grant - is skipped so a download
    cannot silently pick something that installs and then will not run.
    """
    candidates = [a for a in assets if str(a.get("name", "")).lower().endswith(".ipa")]
    excluded = ("trollstore", "jb", "jailbreak", "debug")
    preferred = [
        a for a in candidates
        if not any(word in str(a.get("name", "")).lower() for word in excluded)
    ]
    pool = preferred or candidates
    # Shortest name wins: "LiveContainer.ipa" over "LiveContainer.Something.ipa".
    return min(pool, key=lambda a: len(str(a.get("name", "")))) if pool else None


def download(
    directory: str | None = None, *, on_progress: ProgressFn | None = None
) -> dict[str, Any]:
    """Download the newest LiveContainer IPA and return where it landed."""
    progress: ProgressFn = on_progress or (lambda *_args: None)
    release = latest_release()

    target_dir = Path(directory).expanduser().resolve() if directory else _default_dir()
    try:
        target_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise LiveContainerError(
            f"Cannot write to {target_dir}: {exc.strerror or exc}"
        ) from exc
    destination = target_dir / str(release["asset_name"])

    progress("download", 0, f"Downloading LiveContainer {release['version']}\u2026")
    written = _stream(str(release["url"]), destination, release.get("bytes") or 0, progress)

    expected = release.get("bytes") or 0
    if expected and written != expected:
        destination.unlink(missing_ok=True)
        raise LiveContainerError(
            f"The LiveContainer download ended early ({written} of {expected} bytes) "
            "and was discarded. Check your connection and try again."
        )

    # An .ipa that is not LiveContainer would sign happily and then make no sense, so
    # confirm what was downloaded before handing the path back.
    info = ipa_module.inspect(str(destination))
    if not is_livecontainer(info):
        destination.unlink(missing_ok=True)
        raise LiveContainerError(
            f"{release['asset_name']} is {info.get('bundle_id')}, not LiveContainer. "
            "The release layout may have changed; download it yourself and pick it."
        )

    return {**release, "path": str(destination), "bytes_written": written}


def _default_dir() -> Path:
    from . import paths

    return paths.downloads_dir()


def _stream(url: str, destination: Path, total: int, progress: ProgressFn) -> int:
    try:
        response = requests.get(url, stream=True, timeout=_TIMEOUTS, allow_redirects=True)
    except requests.RequestException as exc:
        raise LiveContainerError(
            "Could not download LiveContainer. Check your internet connection."
        ) from exc

    with response:
        if response.status_code != 200:
            raise LiveContainerError(
                f"GitHub did not serve the LiveContainer IPA (HTTP {response.status_code})."
            )
        written = 0
        try:
            with destination.open("wb") as handle:
                for chunk in response.iter_content(chunk_size=_CHUNK_BYTES):
                    if not chunk:
                        continue
                    handle.write(chunk)
                    written += len(chunk)
                    percent = round(written * 100 / total) if total else None
                    progress("download", percent, _downloaded_step(written, total))
        except (requests.RequestException, OSError) as exc:
            destination.unlink(missing_ok=True)
            raise LiveContainerError(
                f"The LiveContainer download failed after {written} bytes "
                "and was discarded."
            ) from exc
    return written


def _downloaded_step(written: int, total: int) -> str:
    mb = 1 << 20
    if total:
        return f"Downloading LiveContainer \u00b7 {written // mb} / {total // mb} MB"
    return f"Downloading LiveContainer \u00b7 {written // mb} MB"


# --------------------------------------------------------------------------- #
# Handing over the certificate
# --------------------------------------------------------------------------- #
def _import_request(bundle: dict[str, Any]) -> bytes:
    """The plist tools/lc-cert-import/ reads on first launch."""
    return plistlib.dumps(
        {
            "AppGroupID": app_group_identifiers(bundle["team_id"])[0],
            "CertificateData": Path(bundle["p12_path"]).read_bytes(),
            "CertificatePassword": bundle["p12_password"],
        },
        fmt=plistlib.FMT_BINARY,
    )


async def _write_documents(
    bundle_id: str, serial: str | None, files: dict[str, bytes]
) -> None:
    """Write files into an installed app's Documents directory over house_arrest."""
    from pymobiledevice3.services.house_arrest import HouseArrestService

    client = await lockdown.create(serial)
    try:
        async with await HouseArrestService.create(client, bundle_id) as service:
            for name, payload in files.items():
                await service.set_file_contents(f"/Documents/{name}", payload)
    finally:
        await lockdown.close(client)


def seed_certificate(
    bundle: dict[str, Any], serial: str | None = None, *, automatic: bool = True
) -> dict[str, Any]:
    """Put the signing certificate where LiveContainer can pick it up.

    Always writes the bare ``.p12``, which is what LiveContainer's own
    Settings -> Import Certificate reads, so a manual import is possible either way.
    When ``automatic``, also writes the request the injected dylib consumes, which
    removes both files once it has stored the certificate.
    """
    files = {CERTIFICATE_NAME: Path(bundle["p12_path"]).read_bytes()}
    if automatic:
        files[REQUEST_NAME] = _import_request(bundle)

    try:
        asyncio.run(_write_documents(bundle["bundle_id"], serial, files))
    except Exception as exc:  # noqa: BLE001 - any transport failure means the same thing
        # Not fatal: LiveContainer is installed and usable, it just cannot sign guest
        # apps until a certificate reaches it. Say exactly that instead of failing the
        # whole setup after the app is already on the phone.
        return {
            "seeded": False,
            "automatic": False,
            "error": str(exc),
            "instructions": _manual_instructions(bundle),
        }

    return {
        "seeded": True,
        "automatic": automatic,
        "password": bundle["p12_password"],
        "instructions": None if automatic else _manual_instructions(bundle),
    }


def _manual_instructions(bundle: dict[str, Any]) -> str:
    return (
        "In LiveContainer, open Settings \u2192 Import Certificate, choose "
        f"On My iPhone \u2192 LiveContainer \u2192 {CERTIFICATE_NAME}, and enter the "
        f"password {bundle['p12_password']}."
    )


# --------------------------------------------------------------------------- #
# The whole flow
# --------------------------------------------------------------------------- #
def setup(
    ipa_path: str,
    udid: str | None = None,
    *,
    keep_signed: bool = False,
    signed_dir: str | None = None,
    automatic_certificate: bool = True,
    on_progress: ProgressFn | None = None,
) -> dict[str, Any]:
    """Sign and install LiveContainer, then give it the certificate.

    Runs through the ordinary sideload path with LiveContainer's signing profile, so it
    is recorded for auto-refresh like any other app and re-signed with the same
    entitlements when its profile expires.
    """
    from . import sideload  # imported here: sideload resolves our signing profile

    progress: ProgressFn = on_progress or (lambda *_args: None)

    info = ipa_module.inspect(ipa_path)
    if not is_livecontainer(info):
        raise LiveContainerError(
            f"{Path(ipa_path).name} is {info.get('bundle_id') or 'not an app'}, not "
            f"LiveContainer. Download it from {PROJECT_URL}/releases."
        )

    # The signing profile injects this; we only need to know whether it is there, to
    # decide between writing the import request and asking the user to import by hand.
    helper = signing.resolve_helper_dylib()
    automatic = automatic_certificate and helper is not None

    result = sideload.run_sideload(
        ipa_path,
        udid,
        # Its extensions are kept, unlike an ordinary sideload: LiveProcess.appex is how
        # LiveContainer runs a guest app alongside another, and stripping it removes that
        # without any visible sign that something was taken away.
        remove_extensions=False,
        remove_uisd=False,
        keep_signed=keep_signed,
        signed_dir=signed_dir,
        profile=SIGNING_PROFILE,
        on_progress=progress,
    )

    progress("certificate", None, "Handing LiveContainer the certificate\u2026")
    bundle = provision.load_bundle()
    certificate = seed_certificate(bundle, result.get("udid"), automatic=automatic)

    return {
        **result,
        "livecontainer_version": info.get("version"),
        "certificate": certificate,
        "helper_dylib": helper,
        "launch_required": automatic and certificate.get("seeded"),
    }


def status(serial: str | None = None) -> dict[str, Any]:
    """Report whether LiveContainer is installed and whether it holds a certificate.

    The certificate itself lives in the app group, which cannot be read from here, so
    the honest answer is drawn from what *is* visible: a pending request means the dylib
    has not run yet, and neither file present means it has been consumed.
    """
    installed = apps.list_installed(serial)
    entry = next(
        (
            {"bundle_id": key, **value}
            for key, value in installed.items()
            if key.startswith(BUNDLE_PREFIX)
        ),
        None,
    )
    if entry is None:
        return {"installed": False}

    documents: list[str] = []
    try:
        documents = asyncio.run(_list_documents(entry["bundle_id"], serial))
    except Exception:  # noqa: BLE001 - a locked or busy device is not a failure here
        documents = []

    return {
        "installed": True,
        "bundle_id": entry["bundle_id"],
        "name": entry.get("name"),
        "version": entry.get("version"),
        "certificate_pending": REQUEST_NAME in documents,
        "certificate_file_present": CERTIFICATE_NAME in documents,
        # LiveContainer creates these on first launch, so their absence means it has
        # been installed but never opened.
        "launched": "Applications" in documents,
    }


async def _list_documents(bundle_id: str, serial: str | None) -> list[str]:
    from pymobiledevice3.services.house_arrest import HouseArrestService

    client = await lockdown.create(serial)
    try:
        async with await HouseArrestService.create(client, bundle_id) as service:
            return list(await service.listdir("/Documents"))
    finally:
        await lockdown.close(client)
