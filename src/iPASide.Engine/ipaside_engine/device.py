"""Device enumeration, identity, and target selection.

Lists iOS devices visible to usbmuxd (USB and network), decides *which* of them a
command with no explicit UDID means, and reads a curated, stable subset of lockdown
values for a chosen device.
"""

from __future__ import annotations

from typing import Any

from . import lockdown
from ._asyncutil import maybe_await, run
from .errors import EngineError


class DeviceError(EngineError):
    """No device to act on, or no way to tell which one was meant."""


async def _list_devices_async() -> list[dict[str, Any]]:
    from pymobiledevice3 import usbmux

    devices = await maybe_await(usbmux.list_devices())
    result: list[dict[str, Any]] = []
    for dev in devices:
        result.append(
            {
                "serial": getattr(dev, "serial", None),
                "connection_type": getattr(dev, "connection_type", None),
                "device_id": getattr(dev, "devid", getattr(dev, "device_id", None)),
            }
        )
    return result


def list_devices() -> list[dict[str, Any]]:
    """List every iOS device currently visible to usbmuxd (USB and network)."""
    return run(_list_devices_async())


def _targetable_udids(entries: list[dict[str, Any]]) -> list[str]:
    """The distinct devices in a usbmux listing, in the order first seen.

    usbmux reports one entry *per transport*, so a phone that is plugged in and also
    reachable over Wi-Fi is listed twice under the same serial. That is one device
    with two ways in, not two devices. Entries with no serial are dropped: whatever
    they are, they cannot be named as a target. (``doctor`` groups the same way for
    display, but keeps placeholders for unusable entries so it can still show them.)
    """
    udids: list[str] = []
    for entry in entries:
        serial = entry.get("serial")
        if serial and str(serial) not in udids:
            udids.append(str(serial))
    return udids


def _choose_udid(entries: list[dict[str, Any]]) -> str:
    """The one device in ``entries``, or a ``DeviceError`` explaining the problem.

    Deliberately refuses to pick when there is a real choice to make. Taking the
    first entry means the phone iPASide acts on is decided by usbmux's ordering,
    which nothing tells the user about - so an install can land on the wrong phone.
    """
    udids = _targetable_udids(entries)
    if not udids:
        raise DeviceError("No device connected; connect an iPhone (or pass --udid).")
    if len(udids) > 1:
        raise DeviceError(
            f"More than one device is connected ({', '.join(udids)}). "
            "Pass --udid to choose one, or disconnect the others."
        )
    return udids[0]


def resolve_serial(serial: str | None = None) -> str:
    """The UDID to act on: the one given, or the single connected device.

    An explicit serial is taken at face value - the caller has already chosen, and
    re-checking it would only add a usbmux round trip and a new way to fail.
    """
    if serial:
        return serial
    return _choose_udid(list_devices())


async def resolve_serial_async(serial: str | None = None) -> str:
    """``resolve_serial`` for callers already inside the event loop."""
    if serial:
        return serial
    return _choose_udid(await _list_devices_async())


# Fields surfaced for a connected device. Kept small and stable so the UI can
# rely on them; the raw lockdown value bag has hundreds of keys.
_INFO_KEYS = (
    "DeviceName",
    "ProductType",
    "ProductVersion",
    "BuildVersion",
    "UniqueDeviceID",
    "SerialNumber",
    "CPUArchitecture",
    "DeviceClass",
    "HardwareModel",
    "ProductName",
)


async def _get_device_info_async(serial: str | None, prefer_usb: bool) -> dict[str, Any]:
    client = await lockdown.create(serial, prefer_usb=prefer_usb)
    try:
        values = await lockdown.all_values(client)
        return {key: values[key] for key in _INFO_KEYS if key in values}
    finally:
        await lockdown.close(client)


def get_device_info(serial: str | None = None, prefer_usb: bool = True) -> dict[str, Any]:
    """Return a curated lockdown value bag for one device (USB preferred)."""
    return run(_get_device_info_async(serial, prefer_usb))
