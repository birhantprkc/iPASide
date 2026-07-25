"""Tests for noticing an .ipa built for something other than iPhone or iPad.

Asked on r/sideloaded whether iPASide can install to an Apple TV. It cannot, and the
reason it matters that we say so early is that a tvOS `.ipa` is indistinguishable from
an iOS one until the Info.plist is read: same zip, same `Payload/<App>.app`, same keys.
Signed as iOS it provisions cleanly, uploads, and is refused by the device at the last
step with nothing that points at the platform.
"""

from __future__ import annotations

import plistlib
import zipfile

import pytest

from ipaside_engine import ipa, sideload


def build_ipa(path, info: dict) -> str:
    """A minimal .ipa carrying `info` as its Info.plist."""
    target = path / "Sample.ipa"
    with zipfile.ZipFile(target, "w") as zf:
        zf.writestr("Payload/Sample.app/Info.plist", plistlib.dumps(info))
        zf.writestr("Payload/Sample.app/Sample", b"\xcf\xfa\xed\xfe" + b"\x00" * 60)
    return str(target)


BASE = {"CFBundleIdentifier": "com.example.sample", "CFBundleExecutable": "Sample"}


# --- reading the platform out of an Info.plist ------------------------------- #

@pytest.mark.parametrize(
    ("info", "expected"),
    [
        ({"CFBundleSupportedPlatforms": ["iPhoneOS"]}, "ios"),
        ({"CFBundleSupportedPlatforms": ["AppleTVOS"]}, "tvos"),
        ({"CFBundleSupportedPlatforms": ["WatchOS"]}, "watchos"),
        ({"CFBundleSupportedPlatforms": ["XROS"]}, "visionos"),
        # UIDeviceFamily is the fallback: 1 iPhone, 2 iPad, 3 Apple TV, 4 Watch.
        ({"UIDeviceFamily": [1]}, "ios"),
        ({"UIDeviceFamily": [2]}, "ios"),
        ({"UIDeviceFamily": [1, 2]}, "ios"),
        ({"UIDeviceFamily": [3]}, "tvos"),
        ({"UIDeviceFamily": [4]}, "watchos"),
        # Nothing to go on.
        ({}, None),
    ],
)
def test_the_platform_is_read_from_the_plist(info, expected):
    assert ipa._platform(info) == expected


def test_the_explicit_platform_wins_over_the_device_family():
    # Xcode writes both; the platform list is the direct statement.
    assert ipa._platform(
        {"CFBundleSupportedPlatforms": ["AppleTVOS"], "UIDeviceFamily": [3]}
    ) == "tvos"


def test_a_universal_build_that_also_claims_ios_is_ios():
    assert ipa._platform({"UIDeviceFamily": [1, 2, 3]}) == "ios", (
        "an app that runs on iPhone is installable, whatever else it also supports"
    )


def test_inspect_reports_the_platform(tmp_path):
    report = ipa.inspect(build_ipa(tmp_path, {**BASE, "CFBundleSupportedPlatforms": ["AppleTVOS"]}))
    assert report["platform"] == "tvos"


def test_an_ordinary_iphone_ipa_reads_as_ios(tmp_path):
    report = ipa.inspect(build_ipa(tmp_path, {**BASE, "UIDeviceFamily": [1]}))
    assert report["platform"] == "ios"


# --- and refusing it, before Apple or the device is involved ----------------- #

def test_a_tvos_ipa_is_refused_by_name_and_platform(tmp_path):
    path = build_ipa(tmp_path, {**BASE, "CFBundleSupportedPlatforms": ["AppleTVOS"]})

    with pytest.raises(sideload.SideloadError) as caught:
        sideload.run_sideload(path, "0000")

    message = str(caught.value)
    assert "Sample.ipa" in message, "say which file"
    assert "Apple TV (tvOS)" in message, "and what it is for"
    assert "iPhone and iPad only" in message, "and what iPASide does"


def test_a_watchos_ipa_is_refused_too(tmp_path):
    path = build_ipa(tmp_path, {**BASE, "UIDeviceFamily": [4]})

    with pytest.raises(sideload.SideloadError, match="Apple Watch"):
        sideload.run_sideload(path, "0000")


def test_an_ipa_that_does_not_say_is_allowed_through(tmp_path):
    """No platform recorded is not evidence of the wrong platform.

    Older and repackaged IPAs omit both keys. Refusing those would block apps that
    install perfectly well, so the check only fires on a positive statement.
    """
    path = build_ipa(tmp_path, BASE)

    # Gets past the platform gate and fails later, on the device it cannot reach.
    with pytest.raises(Exception) as caught:
        sideload.run_sideload(path, "0000")
    assert "iPhone and iPad only" not in str(caught.value)
