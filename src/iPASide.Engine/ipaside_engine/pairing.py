"""Pairing files this PC holds, and the apps on the phone that consume them.

A pairing file is this computer's trusted identity with one iPhone. SideStore,
AltStore, LiveContainer, EscapeOS, and StikDebug each look for that file in their
own Documents folder, under a name of their own. iPASide already had the SideStore
path; this module is the one place that knows every consumer, can export the file,
and can import the merged lockdown + Remote Pairing record iLoader writes.

Windows usbmux writes the lockdown half (certificates, HostID, escrow) and omits
``UDID`` because the file name carries it. Remote Pairing keys (``identifier``,
Ed25519 ``public_key`` / ``private_key``, ``alt_irk``) are not in that record.
iOS 26.4 and later tunnels that EscapeOS and StikDebug use need those keys.
Importing an iLoader file is how they get onto this PC; placing the result is how
they get onto the phone.
"""

from __future__ import annotations

import asyncio
import plistlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from . import apps, paths
from .errors import EngineError

#: Where usbmux keeps the pairing records this PC has for its devices.
_LOCKDOWN_DIR = Path(r"C:\ProgramData\Apple\Lockdown")

#: Keys iLoader adds so a Remote Pairing tunnel can start. ``alt_irk`` is useful
#: but not required for ``rp_pairing_file_read``.
_RP_REQUIRED_KEYS = ("identifier", "public_key", "private_key")

#: Why a lockdown-only file is not enough for EscapeOS on current iOS.
MISSING_RP_WARNING = (
    "This file has this PC's USB pairing keys, which SideStore and AltStore use. "
    "EscapeOS and StikDebug on iOS 26.4 and later also need Remote Pairing keys. "
    "Import an iLoader pairing file for this iPhone, then place it on the device."
)

HAS_RP_NOTE = (
    "This file includes Remote Pairing keys, so EscapeOS and StikDebug can use it "
    "on iOS 26.4 and later."
)


class PairingError(EngineError):
    """The pairing file could not be read, imported, exported, or placed."""


@dataclass(frozen=True)
class PairingConsumer:
    """One installed app that reads a pairing file out of its own container."""

    id: str
    name: str
    filename: str
    directories: tuple[str, ...]
    needs_rppairing: bool
    prefixes: tuple[str, ...]

    def matches(self, bundle_id: str) -> bool:
        """True when ``bundle_id`` is this app, including a team-id suffix."""
        lowered = bundle_id.lower()
        for prefix in self.prefixes:
            needle = prefix.lower()
            if lowered == needle or lowered.startswith(f"{needle}."):
                return True
        return False


#: LiveContainer's SideStore Documents, kept here so pairing placement and the
#: LiveContainer setup path write the same file to the same place.
SIDESTORE_DOCUMENTS = "/Documents/SideStore/Documents"
ALT_PAIRING_NAME = "ALTPairingFile.mobiledevicepairing"
RP_PAIRING_NAME = "pairingFile.plist"

CONSUMERS: tuple[PairingConsumer, ...] = (
    PairingConsumer(
        id="escapeos",
        name="EscapeOS",
        filename=RP_PAIRING_NAME,
        directories=("/Documents",),
        needs_rppairing=True,
        prefixes=("com.ipaside.escapeos",),
    ),
    PairingConsumer(
        id="livecontainer",
        name="LiveContainer",
        filename=ALT_PAIRING_NAME,
        directories=(SIDESTORE_DOCUMENTS, "/Documents"),
        needs_rppairing=False,
        prefixes=("com.kdt.livecontainer",),
    ),
    PairingConsumer(
        id="sidestore",
        name="SideStore",
        filename=ALT_PAIRING_NAME,
        directories=("/Documents",),
        needs_rppairing=False,
        prefixes=("com.sidestore.sidestore",),
    ),
    PairingConsumer(
        id="altstore",
        name="AltStore",
        filename=ALT_PAIRING_NAME,
        directories=("/Documents",),
        needs_rppairing=False,
        prefixes=("com.rileytestut.altstore",),
    ),
    PairingConsumer(
        id="stikdebug",
        name="StikDebug",
        filename=RP_PAIRING_NAME,
        directories=("/Documents",),
        needs_rppairing=True,
        prefixes=("com.stik.stikdebug", "com.stik.stikjit"),
    ),
)


def pairing_dir() -> Path:
    """Per-device imported pairing files, outside Apple's Lockdown folder.

    Apple's directory is the usbmux record. An iLoader file is a different
    document, and writing it there would mix a credential we did not create with
    the one Windows owns. Keeping it under iPASide's data directory means clearing
    iPASide state drops the import without touching the USB pairing.
    """
    path = paths.data_dir() / "pairing"
    path.mkdir(parents=True, exist_ok=True)
    return path


def match_consumer(bundle_id: str) -> PairingConsumer | None:
    """The consumer ``bundle_id`` belongs to, or None when it is not one of ours."""
    for consumer in CONSUMERS:
        if consumer.matches(bundle_id):
            return consumer
    return None


def has_lockdown_keys(record: dict[str, Any]) -> bool:
    """True when the record can drive a lockdown / minimuxer session."""
    return bool(record.get("DeviceCertificate") and record.get("HostCertificate"))


def has_rppairing_keys(record: dict[str, Any]) -> bool:
    """True when ``rp_pairing_file_read`` has the keys it actually parses."""
    return all(record.get(key) not in (None, b"", "") for key in _RP_REQUIRED_KEYS)


def lockdown_xml(udid: str, *, lockdown_dir: Path | None = None) -> bytes:
    """This PC's usbmux record for ``udid``, with the ``UDID`` key SideStore needs.

    usbmux writes every key a lockdown session needs but not ``UDID`` - the file
    name carries that. SideStore is handed the file on its own, with no name to
    read, so without the key it rejects an otherwise complete record as invalid.
    """
    record = _load_lockdown(udid, lockdown_dir or _LOCKDOWN_DIR)
    record.setdefault("UDID", udid)
    return plistlib.dumps(record, fmt=plistlib.FMT_XML)


def payload_bytes(udid: str, *, lockdown_dir: Path | None = None) -> bytes:
    """The pairing file that should be exported or placed for ``udid``.

    An imported iLoader file wins, because that is the one that carries Remote
    Pairing keys. Missing lockdown keys in the import are filled from usbmux so a
    Remote-Pairing-only document still works for SideStore. With no import, this
    is the usbmux record plus ``UDID``.
    """
    record = payload_record(udid, lockdown_dir=lockdown_dir)
    return plistlib.dumps(record, fmt=plistlib.FMT_XML)


def payload_record(udid: str, *, lockdown_dir: Path | None = None) -> dict[str, Any]:
    """The pairing dict :func:`payload_bytes` serialises, without dumping it."""
    directory = lockdown_dir or _LOCKDOWN_DIR
    imported = _read_imported(udid)
    lockdown: dict[str, Any] | None = None
    try:
        lockdown = _load_lockdown(udid, directory)
        lockdown.setdefault("UDID", udid)
    except PairingError:
        lockdown = None

    if imported is None and lockdown is None:
        raise PairingError(_missing_record_message())

    if imported is None:
        return lockdown  # type: ignore[return-value]

    # Imported keys win: iLoader already merged both halves when it wrote the file.
    merged = {**(lockdown or {}), **imported}
    merged.setdefault("UDID", udid)
    return merged


def inspect_record(udid: str, *, lockdown_dir: Path | None = None) -> dict[str, Any]:
    """What this PC holds for ``udid``, without talking to the phone."""
    directory = lockdown_dir or _LOCKDOWN_DIR
    imported_file = _imported_path(udid)
    imported_present = imported_file.is_file()
    lockdown_present = False
    try:
        _load_lockdown(udid, directory)
        lockdown_present = True
    except PairingError:
        pass

    source = "none"
    record: dict[str, Any] | None = None
    error: str | None = None
    try:
        record = payload_record(udid, lockdown_dir=directory)
        source = "imported" if imported_present else "lockdown"
    except PairingError as exc:
        error = str(exc)

    has_lockdown = has_lockdown_keys(record) if record else lockdown_present
    has_rp = has_rppairing_keys(record) if record else False
    return {
        "udid": udid,
        "source": source,
        "has_lockdown": has_lockdown,
        "has_rppairing": has_rp,
        "imported": imported_present,
        "imported_path": str(imported_file) if imported_present else None,
        "bytes": len(plistlib.dumps(record, fmt=plistlib.FMT_XML)) if record else 0,
        "note": HAS_RP_NOTE if has_rp else (MISSING_RP_WARNING if record else None),
        "error": error,
    }


def status(udid: str, serial: str | None = None, *, lockdown_dir: Path | None = None) -> dict[str, Any]:
    """PC-side pairing health plus which supported apps are actually installed."""
    report = inspect_record(udid, lockdown_dir=lockdown_dir)
    consumers, reachable, device_error = _installed_consumers(serial or udid)
    report["consumers"] = consumers
    report["device_reachable"] = reachable
    report["device_error"] = device_error
    return report


def export_to(udid: str, destination: str | Path, *, lockdown_dir: Path | None = None) -> dict[str, Any]:
    """Write the pairing file for ``udid`` to ``destination`` as XML."""
    payload = payload_bytes(udid, lockdown_dir=lockdown_dir)
    path = Path(destination).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    record = plistlib.loads(payload)
    return {
        "exported": True,
        "path": str(path.resolve()),
        "bytes": len(payload),
        "has_lockdown": has_lockdown_keys(record),
        "has_rppairing": has_rppairing_keys(record),
        "note": HAS_RP_NOTE if has_rppairing_keys(record) else MISSING_RP_WARNING,
    }


def import_from(
    udid: str,
    source: str | Path,
    *,
    lockdown_dir: Path | None = None,
) -> dict[str, Any]:
    """Store ``source`` as this PC's pairing file for ``udid``.

    The file is validated, checked against ``udid`` so another phone's record
    cannot be attached by accident, merged with the usbmux lockdown half when the
    import is Remote-Pairing-only, and written under iPASide's data directory.
    """
    path = Path(source).expanduser()
    if not path.is_file():
        raise PairingError(f"{path} is not a file, so it cannot be imported as a pairing record.")
    try:
        parsed = plistlib.loads(path.read_bytes())
    except (OSError, ValueError) as exc:
        raise PairingError(f"{path} is not a pairing plist: {exc}") from exc
    if not isinstance(parsed, dict):
        raise PairingError(f"{path} is a plist, but not a pairing record (expected a dictionary).")
    if not has_lockdown_keys(parsed) and not has_rppairing_keys(parsed):
        raise PairingError(
            f"{path} has neither USB pairing certificates nor Remote Pairing keys, "
            "so it is not a pairing file."
        )
    _reject_foreign_udid(parsed, udid)

    directory = lockdown_dir or _LOCKDOWN_DIR
    lockdown: dict[str, Any] | None = None
    try:
        lockdown = _load_lockdown(udid, directory)
        lockdown.setdefault("UDID", udid)
    except PairingError:
        lockdown = None
    merged = {**(lockdown or {}), **parsed}
    merged.setdefault("UDID", udid)

    stored = _imported_path(udid)
    stored.write_bytes(plistlib.dumps(merged, fmt=plistlib.FMT_XML))
    return {
        "imported": True,
        "path": str(stored),
        "from": str(path.resolve()),
        "has_lockdown": has_lockdown_keys(merged),
        "has_rppairing": has_rppairing_keys(merged),
        "note": HAS_RP_NOTE if has_rppairing_keys(merged) else MISSING_RP_WARNING,
    }


def deliver_to_app(
    bundle_id: str,
    udid: str,
    serial: str | None = None,
    *,
    consumer: PairingConsumer | None = None,
    payload: bytes | None = None,
    lockdown_dir: Path | None = None,
) -> dict[str, Any]:
    """Write the pairing file into one installed app's Documents."""
    matched = consumer or match_consumer(bundle_id)
    if matched is None:
        raise PairingError(
            f"{bundle_id} is not a pairing-file consumer iPASide knows about."
        )
    body = payload if payload is not None else payload_bytes(udid, lockdown_dir=lockdown_dir)
    record = plistlib.loads(body)
    warning = None
    if matched.needs_rppairing and not has_rppairing_keys(record):
        warning = MISSING_RP_WARNING
    try:
        written = _write_into(bundle_id, serial, {matched.filename: body}, matched.directories)
    except Exception as exc:  # noqa: BLE001 - any transport failure means the same thing
        return {
            "id": matched.id,
            "name": matched.name,
            "bundle_id": bundle_id,
            "filename": matched.filename,
            "placed": False,
            "error": str(exc),
            "warning": warning,
        }
    return {
        "id": matched.id,
        "name": matched.name,
        "bundle_id": bundle_id,
        "filename": matched.filename,
        "placed": True,
        "bytes": len(body),
        "written": written,
        "warning": warning,
    }


def deliver_if_consumer(
    bundle_id: str,
    udid: str,
    serial: str | None = None,
    *,
    skip_ids: Iterable[str] = (),
    lockdown_dir: Path | None = None,
) -> dict[str, Any] | None:
    """Place the pairing file after a sideload, or None when the app does not use one.

    LiveContainer's pairing file is delivered by its signing profile, which also
    knows whether that build carries SideStore. Skipping it here stops a plain
    LiveContainer install being handed a credential it has no store to use.
    """
    matched = match_consumer(bundle_id)
    if matched is None or matched.id in set(skip_ids):
        return None
    try:
        return deliver_to_app(
            bundle_id, udid, serial, consumer=matched, lockdown_dir=lockdown_dir
        )
    except PairingError as exc:
        return {
            "id": matched.id,
            "name": matched.name,
            "bundle_id": bundle_id,
            "filename": matched.filename,
            "placed": False,
            "error": str(exc),
        }


def deliver_to_device(
    udid: str,
    serial: str | None = None,
    *,
    lockdown_dir: Path | None = None,
) -> dict[str, Any]:
    """Place the pairing file in every supported app currently installed."""
    payload = payload_bytes(udid, lockdown_dir=lockdown_dir)
    record = plistlib.loads(payload)
    installed = apps.list_installed(serial or udid)
    placed: list[dict[str, Any]] = []
    for bundle_id in sorted(installed):
        matched = match_consumer(bundle_id)
        if matched is None:
            continue
        placed.append(
            deliver_to_app(
                bundle_id,
                udid,
                serial or udid,
                consumer=matched,
                payload=payload,
                lockdown_dir=lockdown_dir,
            )
        )
    return {
        "udid": udid,
        "has_lockdown": has_lockdown_keys(record),
        "has_rppairing": has_rppairing_keys(record),
        "note": HAS_RP_NOTE if has_rppairing_keys(record) else MISSING_RP_WARNING,
        "bytes": len(payload),
        "placed": placed,
        "supported_installed": len(placed),
    }


def _installed_consumers(serial: str) -> tuple[list[dict[str, Any]], bool, str | None]:
    """Supported apps on the phone, or an empty list when the phone cannot be listed."""
    try:
        installed = apps.list_installed(serial)
    except Exception as exc:  # noqa: BLE001 - status must still describe the PC-side file
        return [], False, str(exc)
    consumers: list[dict[str, Any]] = []
    for bundle_id in sorted(installed):
        matched = match_consumer(bundle_id)
        if matched is None:
            continue
        meta = installed[bundle_id]
        consumers.append(
            {
                "id": matched.id,
                "name": matched.name,
                "bundle_id": bundle_id,
                "app_name": meta.get("name") or matched.name,
                "filename": matched.filename,
                "needs_rppairing": matched.needs_rppairing,
            }
        )
    return consumers, True, None


def _load_lockdown(udid: str, lockdown_dir: Path) -> dict[str, Any]:
    """The usbmux plist for ``udid``, or PairingError when there is none."""
    source = _find_lockdown_file(udid, lockdown_dir)
    if source is None:
        raise PairingError(_missing_record_message())
    try:
        parsed = plistlib.loads(source.read_bytes())
    except (OSError, ValueError) as exc:
        raise PairingError(f"The pairing record at {source} could not be read: {exc}") from exc
    if not isinstance(parsed, dict):
        raise PairingError(f"The pairing record at {source} is not a dictionary.")
    return parsed


def _find_lockdown_file(udid: str, lockdown_dir: Path) -> Path | None:
    """The usbmux file for ``udid``, matching on the file name first, then the UDID key."""
    if not lockdown_dir.is_dir():
        return None
    exact = lockdown_dir / f"{udid}.plist"
    if exact.exists():
        return exact
    wanted = _folded_udid(udid)
    for path in sorted(lockdown_dir.glob("*.plist")):
        try:
            parsed = plistlib.loads(path.read_bytes())
        except (OSError, ValueError):
            continue
        if not isinstance(parsed, dict):
            continue
        if _folded_udid(str(parsed.get("UDID", ""))) == wanted:
            return path
    return None


def _imported_path(udid: str) -> Path:
    """Where an imported file for ``udid`` is stored, creating no file."""
    directory = pairing_dir()
    exact = directory / f"{udid}.plist"
    if exact.exists():
        return exact
    wanted = _folded_udid(udid)
    for path in directory.glob("*.plist"):
        if _folded_udid(path.stem) == wanted:
            return path
    return exact


def _read_imported(udid: str) -> dict[str, Any] | None:
    path = _imported_path(udid)
    if not path.is_file():
        return None
    try:
        parsed = plistlib.loads(path.read_bytes())
    except (OSError, ValueError):
        return None
    return parsed if isinstance(parsed, dict) else None


def _reject_foreign_udid(record: dict[str, Any], udid: str) -> None:
    """Refuse a file that already names a different device."""
    listed = record.get("UDID")
    if not listed:
        return
    if _folded_udid(str(listed)) != _folded_udid(udid):
        raise PairingError(
            f"That pairing file is for {listed}, not {udid}. Import a file from "
            "iLoader that was made with this iPhone."
        )


def _write_into(
    bundle_id: str,
    serial: str | None,
    files: dict[str, bytes],
    directories: tuple[str, ...],
) -> list[str]:
    """House Arrest write, delegated so LiveContainer tests can still patch it."""
    from . import livecontainer

    return asyncio.run(
        livecontainer._write_documents(
            bundle_id, serial, files, directories=directories
        )
    )


def _folded_udid(value: str) -> str:
    return value.replace("-", "").lower()


def _missing_record_message() -> str:
    return (
        "This PC has no pairing record for the device, so on-device refresh cannot "
        "be set up. Reconnect it over USB and trust this computer, then try again."
    )
