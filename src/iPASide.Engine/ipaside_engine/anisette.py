"""Anisette provider.

Anisette headers are the device-provisioning data Apple's GrandSlam (GSA)
servers require to authenticate an Apple ID from a non-Apple machine. iPASide
generates them fully in-process using the pure-Python ``anisette`` package,
which runs Apple's own portable provisioning libraries (downloaded once, ~3MB,
then cached). No account information is contained in anisette data, and nothing
is sent to any third-party server.

The combined library bundle + provisioning state is persisted to a single cache
file so the machine presents as a stable, already-provisioned device on every
run - re-provisioning repeatedly is what trips Apple's anti-abuse checks.
"""

from __future__ import annotations

from importlib import metadata
from typing import Any

from . import paths


def _load_provider() -> Any:
    """Return a ready, provisioned Anisette provider, persisting its state."""
    from anisette import Anisette

    state = paths.anisette_state_file()
    if state.exists():
        provider = Anisette.load(str(state))
    else:
        # First use downloads Apple's portable provisioning libraries.
        provider = Anisette.init()

    if not provider.is_provisioned:
        provider.provision()

    provider.save_all(str(state))
    return provider


def get_headers() -> dict[str, Any]:
    """Return a fresh set of anisette headers for a GSA request."""
    provider = _load_provider()
    return dict(provider.get_data())


def status() -> dict[str, Any]:
    """Report anisette readiness without forcing provisioning."""
    try:
        version: str | None = metadata.version("Anisette")
    except metadata.PackageNotFoundError:
        version = None
    state = paths.anisette_state_file()
    return {
        "available": version is not None,
        "package_version": version,
        "state_cached": state.exists(),
        "state_path": str(state),
    }
