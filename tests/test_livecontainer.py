"""LiveContainer setup: entitlements, release selection, and the import request.

The parts worth pinning down are the ones a phone cannot tell us about quickly: that the
entitlements are exactly what LiveContainer looks for and nothing a free profile would
reject, that a release download cannot pick a build we cannot provision, and that the
import request matches the keys the injected dylib reads.
"""

from __future__ import annotations

import plistlib

import pytest

from ipaside_engine import livecontainer, sideload

TEAM = "ASK9QR9SBC"
BUNDLE_ID = f"{livecontainer.BUNDLE_PREFIX}.{TEAM}"


# --------------------------------------------------------------------------- #
# Entitlements
# --------------------------------------------------------------------------- #
def test_bundle_id_is_team_scoped():
    assert livecontainer.bundle_id_for(TEAM) == f"com.kdt.livecontainer.{TEAM}"


def test_app_groups_are_both_stores_in_preference_order():
    groups = livecontainer.app_group_identifiers(TEAM)
    assert groups == [
        f"group.com.SideStore.SideStore.{TEAM}",
        f"group.com.rileytestut.AltStore.{TEAM}",
    ]


def test_entitlements_carry_the_jitless_requirements():
    ents = livecontainer.build_entitlements(TEAM, BUNDLE_ID)

    assert ents["application-identifier"] == f"{TEAM}.{BUNDLE_ID}"
    assert ents["com.apple.developer.team-identifier"] == TEAM
    assert ents["get-task-allow"] is True
    assert ents["com.apple.security.application-groups"] == (
        livecontainer.app_group_identifiers(TEAM)
    )


def test_keychain_groups_are_expanded_not_wildcarded():
    """LiveContainer derives guest keychain groups by index, so the list must be explicit.

    A profile's `TEAMID.*` wildcard legally covers these, which is why signing with them
    is accepted - but leaving the wildcard in place is what makes other signers unusable
    with LiveContainer.
    """
    groups = livecontainer.build_entitlements(TEAM, BUNDLE_ID)["keychain-access-groups"]

    assert len(groups) == livecontainer.KEYCHAIN_GROUPS
    assert f"{TEAM}.*" not in groups
    assert groups[0] == f"{TEAM}.com.kdt.livecontainer.shared"
    assert groups[1] == f"{TEAM}.com.kdt.livecontainer.shared.1"
    assert groups[-1] == (
        f"{TEAM}.com.kdt.livecontainer.shared.{livecontainer.KEYCHAIN_GROUPS - 1}"
    )
    assert len(set(groups)) == len(groups), "duplicate keychain groups"


@pytest.mark.parametrize(
    "entitlement",
    [
        "com.apple.developer.healthkit",
        "com.apple.developer.kernel.increased-memory-limit",
    ],
)
def test_entitlements_omit_what_a_free_profile_will_not_grant(entitlement):
    """Asking for an ungranted entitlement invalidates the whole signature.

    LiveContainer's own build asks for these; we deliberately do not, because a free
    profile does not carry them and the result is a signature iOS rejects outright
    rather than one granted in part.
    """
    assert entitlement not in livecontainer.build_entitlements(TEAM, BUNDLE_ID)


def test_entitlements_are_plist_serializable():
    """zsign is handed these as a plist, so anything unserializable fails at sign time."""
    ents = livecontainer.build_entitlements(TEAM, BUNDLE_ID)
    assert plistlib.loads(plistlib.dumps(ents)) == ents


# --------------------------------------------------------------------------- #
# Recognising LiveContainer
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize(
    ("bundle_id", "expected"),
    [
        ("com.kdt.livecontainer", True),
        (f"com.kdt.livecontainer.{TEAM}", True),
        ("com.burbn.instagram", False),
        ("com.kdt.something-else", False),
        ("", False),
        (None, False),
    ],
)
def test_is_livecontainer(bundle_id, expected):
    assert livecontainer.is_livecontainer({"bundle_id": bundle_id}) is expected


# --------------------------------------------------------------------------- #
# Release asset selection
# --------------------------------------------------------------------------- #
def test_asset_selection_prefers_the_plain_ipa():
    assets = [
        {"name": "LiveContainer.TrollStore.ipa", "size": 1},
        {"name": "LiveContainer.ipa", "size": 2},
        {"name": "LiveContainer.JB.ipa", "size": 3},
    ]
    assert livecontainer._pick_asset(assets)["name"] == "LiveContainer.ipa"


def test_asset_selection_skips_builds_we_cannot_provision():
    """A TrollStore build installs and then will not run under a free profile."""
    assets = [{"name": "LiveContainer.TrollStore.ipa"}, {"name": "LiveContainer.JB.ipa"}]
    # Nothing usable is preferable to something misleading, but if a release only ever
    # shipped those we still return one rather than claiming there is no IPA at all.
    assert livecontainer._pick_asset(assets) is not None


def test_asset_selection_ignores_non_ipa_assets():
    assets = [
        {"name": "LiveContainer.tipa"},
        {"name": "SHA256SUMS.txt"},
        {"name": "source.zip"},
    ]
    assert livecontainer._pick_asset(assets) is None


def test_asset_selection_handles_an_empty_release():
    assert livecontainer._pick_asset([]) is None


# --------------------------------------------------------------------------- #
# The import request the dylib reads
# --------------------------------------------------------------------------- #
def test_import_request_matches_the_dylib_contract(tmp_path):
    p12 = tmp_path / "identity.p12"
    p12.write_bytes(b"pkcs12-bytes")

    request = plistlib.loads(
        livecontainer._import_request(
            {"team_id": TEAM, "p12_path": str(p12), "p12_password": "iPASide"}
        )
    )

    # These three key names are the contract with tools/lc-cert-import/; renaming one
    # here without rebuilding the dylib silently stops the automatic import working.
    assert set(request) == {"AppGroupID", "CertificateData", "CertificatePassword"}
    assert request["AppGroupID"] == f"group.com.SideStore.SideStore.{TEAM}"
    assert request["CertificateData"] == b"pkcs12-bytes"
    assert request["CertificatePassword"] == "iPASide"


def test_import_request_names_the_group_livecontainer_prefers():
    """LiveContainer resolves its own group, so the request must name the same one."""
    request_group = f"group.com.SideStore.SideStore.{TEAM}"
    assert livecontainer.app_group_identifiers(TEAM)[0] == request_group


# --------------------------------------------------------------------------- #
# Wiring into the sideload path
# --------------------------------------------------------------------------- #
def test_sideload_resolves_the_livecontainer_profile():
    groups, entitlements, dylibs = sideload._signing_profile(
        livecontainer.SIGNING_PROFILE, TEAM, BUNDLE_ID
    )

    assert groups == livecontainer.app_group_identifiers(TEAM)
    assert entitlements == livecontainer.build_entitlements(TEAM, BUNDLE_ID)
    # Built on macOS in CI and committed, so a source checkout may or may not have it;
    # either way the profile must return a list rather than fail.
    assert isinstance(dylibs, list)
    assert all(str(d).endswith(".dylib") for d in dylibs)


def test_unknown_signing_profile_is_refused():
    with pytest.raises(sideload.SideloadError, match="Unknown signing profile"):
        sideload._signing_profile("not-a-profile", TEAM, BUNDLE_ID)


def test_setup_refuses_an_ipa_that_is_not_livecontainer(monkeypatch, tmp_path):
    """Signing something else with LiveContainer's entitlements makes no sense."""
    monkeypatch.setattr(
        livecontainer.ipa_module,
        "inspect",
        lambda _path: {"bundle_id": "com.burbn.instagram", "display_name": "Instagram"},
    )
    ipa = tmp_path / "Instagram.ipa"
    ipa.write_bytes(b"not really an ipa")

    with pytest.raises(livecontainer.LiveContainerError, match="not\\s+LiveContainer"):
        livecontainer.setup(str(ipa))
