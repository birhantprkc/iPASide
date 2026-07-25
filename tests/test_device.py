"""Tests for deciding which device a command acts on.

usbmux lists one entry *per transport*, so "how many phones are connected" is not
``len(list_devices())``. Getting that wrong goes wrong in both directions: count
transports and a phone on USB + Wi-Fi looks like two devices; take the first entry
and a second phone silently becomes the target of an install.
"""

import asyncio

import pytest

from ipaside_engine import device, lockdown

UDID = "935cbbb9b82d25d15566e5939bcea5677b1c44ae"
OTHER = "0f1e2d3c4b5a69788796a5b4c3d2e1f009876543"


@pytest.fixture
def fake_devices(monkeypatch):
    """Replace the usbmux enumeration - both the sync and the async one."""

    def install(entries):
        async def listing():
            return entries

        monkeypatch.setattr(device, "list_devices", lambda: entries)
        monkeypatch.setattr(device, "_list_devices_async", listing)

    return install


def test_one_phone_on_two_transports_resolves_to_that_phone(fake_devices):
    fake_devices([
        {"serial": UDID, "connection_type": "USB"},
        {"serial": UDID, "connection_type": "Network"},
    ])
    assert device.resolve_serial() == UDID


def test_two_phones_are_never_guessed_between(fake_devices):
    fake_devices([
        {"serial": UDID, "connection_type": "USB"},
        {"serial": OTHER, "connection_type": "Network"},
    ])

    with pytest.raises(device.DeviceError) as failure:
        device.resolve_serial()

    message = str(failure.value)
    assert UDID in message and OTHER in message, "say what there is to choose between"
    assert "--udid" in message, "and how to choose"


def test_an_explicit_udid_is_never_second_guessed(monkeypatch):
    def boom():
        raise AssertionError("an explicit target must not need enumerating")

    monkeypatch.setattr(device, "list_devices", boom)
    assert device.resolve_serial(UDID) == UDID


def test_no_devices_keeps_the_familiar_message(fake_devices):
    fake_devices([])
    with pytest.raises(device.DeviceError, match="No device connected"):
        device.resolve_serial()


def test_an_entry_without_a_serial_is_not_a_target(fake_devices):
    # It cannot be named as a target, so it must neither be chosen itself nor make
    # a real device look like a choice.
    fake_devices([
        {"connection_type": "USB"},
        {"serial": UDID, "connection_type": "USB"},
    ])
    assert device.resolve_serial() == UDID


def test_nothing_but_serial_less_entries_is_no_device(fake_devices):
    fake_devices([{"connection_type": "USB"}])
    with pytest.raises(device.DeviceError, match="No device connected"):
        device.resolve_serial()


def test_the_async_resolver_agrees_with_the_sync_one(fake_devices):
    fake_devices([
        {"serial": UDID, "connection_type": "USB"},
        {"serial": UDID, "connection_type": "Network"},
    ])
    assert asyncio.run(device.resolve_serial_async()) == UDID
    assert asyncio.run(device.resolve_serial_async(OTHER)) == OTHER


def test_lockdown_hands_usbmux_a_resolved_udid_not_a_blank(fake_devices, monkeypatch):
    # Every app list, install and uninstall opens its connection here, and the UI
    # passes no UDID, so this is where a blank would have become "some phone".
    from pymobiledevice3 import lockdown as pymobiledevice3_lockdown

    fake_devices([
        {"serial": UDID, "connection_type": "USB"},
        {"serial": UDID, "connection_type": "Network"},
    ])
    seen = {}

    def fake_create(serial=None, connection_type=None):
        seen["serial"] = serial
        seen["connection_type"] = connection_type
        return "client"

    monkeypatch.setattr(pymobiledevice3_lockdown, "create_using_usbmux", fake_create)

    assert asyncio.run(lockdown.create()) == "client"
    assert seen == {"serial": UDID, "connection_type": "USB"}


def test_lockdown_refuses_to_connect_to_one_of_two_phones(fake_devices):
    fake_devices([
        {"serial": UDID, "connection_type": "USB"},
        {"serial": OTHER, "connection_type": "USB"},
    ])
    with pytest.raises(device.DeviceError, match="More than one device"):
        asyncio.run(lockdown.create())


# --- the CLI's own surface -------------------------------------------------- #
#
# These exist because of a real escape. `sideload` declared its own `--udid` rather
# than sharing the parent every other device command uses, so when `--connection`
# arrived it silently did not get one. The app sent it regardless, which made every
# sideload fail on an argparse error the moment Settings was set to anything but
# Automatic. Pinning the flag matrix is what stops that drifting apart again.

# Commands that open a connection to a phone, and so must accept both flags.
_DEVICE_COMMANDS = [
    "device-info",
    "developer-mode",
    "apps",
    "app-icons",
    "install",
    "uninstall",
    "sideload",
]


@pytest.fixture(scope="module")
def parser():
    from ipaside_engine.__main__ import build_parser

    return build_parser()


@pytest.mark.parametrize("command", _DEVICE_COMMANDS)
@pytest.mark.parametrize("transport", ["usb", "wifi", "auto"])
def test_every_device_command_takes_a_transport(parser, command, transport, tmp_path):
    argv = [command, *_positionals(command, tmp_path), "--connection", transport]
    assert parser.parse_args(argv).connection == transport


@pytest.mark.parametrize("command", _DEVICE_COMMANDS)
def test_every_device_command_takes_a_udid(parser, command, tmp_path):
    argv = [command, *_positionals(command, tmp_path), "--udid", UDID]
    assert parser.parse_args(argv).udid == UDID


@pytest.mark.parametrize("transport", ["usb", "wifi", "auto"])
def test_refresh_takes_a_transport_without_taking_a_device(parser, transport):
    # A refresh reinstalls onto the device each record names, so --udid would mean
    # nothing - but the transport is a preference about this PC, and the unattended
    # daily run has to honour it rather than quietly going over the air.
    assert parser.parse_args(["refresh", "--connection", transport]).connection == transport

    with pytest.raises(SystemExit):
        parser.parse_args(["refresh", "--udid", UDID])


def test_an_unknown_transport_is_refused(parser):
    with pytest.raises(SystemExit):
        parser.parse_args(["device-info", "--connection", "bluetooth"])


def _positionals(command: str, tmp_path) -> list[str]:
    """The required arguments for ``command``, so parsing gets as far as the flags."""
    if command in {"install", "sideload"}:
        return [str(tmp_path / "app.ipa")]
    if command == "uninstall":
        return ["com.example.app"]
    return []
