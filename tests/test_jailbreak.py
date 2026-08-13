"""The jailbreak advisor + Dopamine installer, and the ``jailbreak`` CLI wiring.

The compatibility data is fetched live from a JSON file in the repo, so the advisor
logic is tested against that *real* shipped file (loaded from disk) - a bad edit to the
data fails here - while the network fetch itself is tested with a stub. The installer
and CLI are exercised the same way ``test_cli_livecontainer`` is: stub only the
boundaries iPASide does not own (the network, the device, the sideload).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from ipaside_engine import __main__ as cli
from ipaside_engine import jailbreak

# The real shipped compatibility list, so these tests double as a check on that data.
_COMPAT = json.loads(
    (Path(__file__).resolve().parents[1] / "compat" / "dopamine.json").read_text("utf-8")
)


# --------------------------------------------------------------------------- #
# Device -> chip (from the live list)
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize(
    "product_type, chip",
    [
        ("iPhone10,2", "A11"),  # iPhone 8 Plus
        ("iPhone11,8", "A12"),  # iPhone XR
        ("iPhone12,1", "A13"),  # iPhone 11
        ("iPhone13,2", "A14"),  # iPhone 12
        ("iPhone14,5", "A15"),  # iPhone 13
        ("iPhone15,2", "A16"),  # iPhone 14 Pro
        ("iPhone16,1", "A17"),  # iPhone 15 Pro
        ("iPhone17,1", "A18"),  # iPhone 16 Pro
        ("iPhone18,1", "A19"),  # iPhone 17 Pro
        ("iPad13,4", "M1"),     # iPad Pro 2021
        ("iPad14,3", "M2"),     # iPad Pro 2022
    ],
)
def test_chip_for_known_devices(product_type, chip):
    assert jailbreak.chip_for(_COMPAT, product_type) == chip


def test_chip_for_unknown_device_is_none():
    assert jailbreak.chip_for(_COMPAT, "iPhone99,9") is None
    assert jailbreak.chip_for(_COMPAT, None) is None


def test_device_name_for_iphone_is_marketing_name():
    assert jailbreak.device_name_for(_COMPAT, "iPhone12,1") == "iPhone 11"


# --------------------------------------------------------------------------- #
# Version parsing
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize(
    "text, expected",
    [("16.7.15", (16, 7, 15)), ("26.0", (26, 0, 0)), ("18", (18, 0, 0)), ("  17.3.1  ", (17, 3, 1))],
)
def test_parse_version(text, expected):
    assert jailbreak.parse_version(text) == expected


def test_parse_version_rejects_junk():
    assert jailbreak.parse_version(None) is None
    assert jailbreak.parse_version("") is None
    assert jailbreak.parse_version("beta") is None


# --------------------------------------------------------------------------- #
# The advisor (against the real shipped data)
# --------------------------------------------------------------------------- #
def _advise(product_type, version):
    return jailbreak.advise(product_type, version, _COMPAT)


def test_a13_reaches_ios_26():
    advice = _advise("iPhone12,1", "26.0.1")
    assert advice["outcome"] == jailbreak.SUPPORTED
    assert advice["can_install"] is True
    assert advice["max_supported"] == "26.0.1"


def test_a11_is_supported_up_to_its_ceiling():
    advice = _advise("iPhone10,2", "16.7.15")  # iPhone 8 Plus
    assert advice["outcome"] == jailbreak.SUPPORTED
    assert advice["can_install"] is True
    assert advice["max_supported"] == "16.7.16"


def test_a10_is_supported_and_reaches_18():
    advice = _advise("iPhone9,1", "16.7.15")  # A10, in the 16.7-18.7.1 range
    assert advice["outcome"] == jailbreak.SUPPORTED
    assert advice["max_supported"] == "18.7.1"


def test_a10_gap_between_15_8_8_and_16_7_is_refused():
    advice = _advise("iPhone9,1", "16.3")  # A10 gap
    assert advice["outcome"] == jailbreak.UNSUPPORTED_VERSION
    assert advice["can_install"] is False


def test_a12_cannot_run_ios_26():
    assert _advise("iPhone11,8", "18.7.1")["outcome"] == jailbreak.SUPPORTED
    too_new = _advise("iPhone11,8", "26.0")
    assert too_new["outcome"] == jailbreak.UNSUPPORTED_VERSION


def test_a17_caps_at_17_3_1():
    assert _advise("iPhone16,1", "17.3.1")["outcome"] == jailbreak.SUPPORTED
    too_new = _advise("iPhone16,1", "18.0")
    assert too_new["outcome"] == jailbreak.UNSUPPORTED_VERSION
    assert "supports up to iOS 17.3.1" in too_new["summary"]


def test_a18_and_a19_have_no_jailbreak():
    for product_type in ("iPhone17,1", "iPhone18,1"):
        advice = _advise(product_type, "26.0")
        assert advice["outcome"] == jailbreak.NO_JAILBREAK
        assert advice["can_install"] is False


def test_unknown_device_is_reported_not_guessed():
    advice = _advise("iPhone99,9", "26.0")
    assert advice["outcome"] == jailbreak.UNKNOWN_DEVICE
    assert advice["can_install"] is False


def test_a_supported_chip_below_its_range_is_refused():
    assert _advise("iPhone12,1", "14.0")["outcome"] == jailbreak.UNSUPPORTED_VERSION


def test_a_new_ios_is_a_data_edit_not_a_code_change():
    """The whole point: extend the fetched list and the advisor follows, no code change."""
    compat = json.loads(json.dumps(_COMPAT))  # deep copy
    compat["support"]["A13"] = [["15.0", "18.7.1"], ["26.0", "26.1.0"]]
    advice = jailbreak.advise("iPhone12,1", "26.1", compat)
    assert advice["outcome"] == jailbreak.SUPPORTED
    assert advice["max_supported"] == "26.1"


# --------------------------------------------------------------------------- #
# fetch_compat
# --------------------------------------------------------------------------- #
class _FakeResponse:
    def __init__(self, payload, *, status_ok=True):
        self._payload = payload
        self._status_ok = status_ok

    def raise_for_status(self):
        if not self._status_ok:
            import requests
            raise requests.HTTPError("boom")

    def json(self):
        return self._payload


def test_fetch_compat_returns_the_document(monkeypatch):
    monkeypatch.setattr(
        jailbreak.requests, "get", lambda *a, **k: _FakeResponse(_COMPAT)
    )
    document = jailbreak.fetch_compat()
    assert document["support"]["A13"]


def test_fetch_compat_raises_on_network_failure(monkeypatch):
    import requests

    def boom(*a, **k):
        raise requests.ConnectionError("no net")

    monkeypatch.setattr(jailbreak.requests, "get", boom)
    with pytest.raises(jailbreak.JailbreakError):
        jailbreak.fetch_compat()


def test_fetch_compat_raises_on_malformed_document(monkeypatch):
    monkeypatch.setattr(
        jailbreak.requests, "get", lambda *a, **k: _FakeResponse({"nonsense": True})
    )
    with pytest.raises(jailbreak.JailbreakError):
        jailbreak.fetch_compat()


# --------------------------------------------------------------------------- #
# Asset selection
# --------------------------------------------------------------------------- #
def test_pick_asset_prefers_plain_ipa_over_tipa():
    assets = [
        {"name": "Dopamine.tipa", "browser_download_url": "u1", "size": 1},
        {"name": "Dopamine.ipa", "browser_download_url": "u2", "size": 2},
    ]
    assert jailbreak._pick_asset(assets)["name"] == "Dopamine.ipa"


def test_pick_asset_returns_none_when_only_tipa():
    assert jailbreak._pick_asset([{"name": "Dopamine.tipa", "browser_download_url": "u"}]) is None


# --------------------------------------------------------------------------- #
# download() bundle-id sanity (regression: Dopamine's real id is com.opa334.FuckYou)
# --------------------------------------------------------------------------- #
def _stub_download_boundaries(monkeypatch, tmp_path, bundle_id):
    monkeypatch.setattr(
        jailbreak,
        "latest_release",
        lambda: {"version": "3.0", "asset_name": "Dopamine.ipa", "url": "https://x/i.ipa", "bytes": 4},
    )

    def stream(url, destination, total, progress):
        destination.write_bytes(b"ipa!")
        return 4

    monkeypatch.setattr(jailbreak, "_stream", stream)
    monkeypatch.setattr(jailbreak.ipa_module, "inspect", lambda _p: {"bundle_id": bundle_id})


def test_download_accepts_dopamines_real_bundle_id(monkeypatch, tmp_path):
    # Dopamine's own id is com.opa334.FuckYou - it must NOT be rejected as "not Dopamine".
    _stub_download_boundaries(monkeypatch, tmp_path, "com.opa334.FuckYou")
    result = jailbreak.download(str(tmp_path))
    assert result["path"].endswith("Dopamine.ipa")


def test_download_rejects_a_non_app_payload(monkeypatch, tmp_path):
    _stub_download_boundaries(monkeypatch, tmp_path, "")
    with pytest.raises(jailbreak.JailbreakError):
        jailbreak.download(str(tmp_path))


# --------------------------------------------------------------------------- #
# CLI wiring (network / device / sideload stubbed)
# --------------------------------------------------------------------------- #
@pytest.fixture
def boundaries(monkeypatch, tmp_path):
    """Stub the compat fetch, the device read, and the sideload; parsing stays real."""
    state: dict[str, object] = {"calls": []}

    def fetch_compat():
        state["calls"].append("fetch_compat")
        return _COMPAT

    def get_device_info(serial=None, prefer_usb=True):
        state["calls"].append("device_info")
        return {"ProductType": "iPhone12,1", "ProductVersion": "16.7.15"}

    def download(directory=None, *, on_progress=None):
        state["calls"].append("download")
        path = tmp_path / "Dopamine.ipa"
        path.write_bytes(b"ipa!")
        return {"version": "3.0", "asset_name": "Dopamine.ipa", "path": str(path)}

    def run_sideload(ipa_path, udid=None, **kwargs):
        state["calls"].append("run_sideload")
        state["sideload_ipa"] = ipa_path
        state["sideload_kwargs"] = kwargs
        return {"status": "installed", "bundle_id": "com.opa334.dopamine", "name": "Dopamine"}

    monkeypatch.setattr(jailbreak, "fetch_compat", fetch_compat)
    monkeypatch.setattr(cli.device, "get_device_info", get_device_info)
    monkeypatch.setattr(jailbreak, "download", download)
    from ipaside_engine import sideload as sideload_module

    monkeypatch.setattr(sideload_module, "run_sideload", run_sideload)
    return state


def _run(*args: str) -> int:
    parsed = cli.build_parser().parse_args(["jailbreak", "--json", *args])
    return cli.dispatch(parsed)


def test_advise_fetches_the_list_then_reads_the_device(boundaries, capsys):
    assert _run() == 0
    assert boundaries["calls"] == ["fetch_compat", "device_info"]
    assert "supported" in capsys.readouterr().out


def test_advise_reports_a_fetch_failure_cleanly(monkeypatch, capsys):
    def boom():
        raise jailbreak.JailbreakError("Couldn't fetch the jailbreak compatibility list.")

    monkeypatch.setattr(jailbreak, "fetch_compat", boom)
    assert _run() == 1
    out = capsys.readouterr().out
    assert "compatibility list" in out
    assert "Traceback" not in out


def test_download_only_fetches(boundaries):
    assert _run("--download") == 0
    assert "download" in boundaries["calls"]
    assert "run_sideload" not in boundaries["calls"]


def test_install_downloads_then_sideloads(boundaries):
    assert _run("--install") == 0
    calls = boundaries["calls"]
    assert calls.index("download") < calls.index("run_sideload")


def test_install_keeps_the_jailbreak_extensions(boundaries):
    assert _run("--install") == 0
    assert boundaries["sideload_kwargs"]["remove_extensions"] is False


def test_signed_output_options_reach_the_sideload(boundaries):
    assert _run("--install", "--keep-signed", "--signed-dir", r"D:\signed") == 0
    assert boundaries["sideload_kwargs"]["keep_signed"] is True
    assert boundaries["sideload_kwargs"]["signed_dir"] == r"D:\signed"
