#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Adapted from Hydraulophone/Scripts/read_development_team.py.
# This standalone helper uses the GPLv3 license in LICENSE.device-selector.
"""Resolve a signing team from an override or public certificate metadata.

This reads certificates, never private keys. stdout contains only the Team ID.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys


class DevelopmentTeamError(ValueError):
    pass


def resolve_team(override: str = "") -> str:
    requested = override.strip()
    if requested:
        if not re.fullmatch(r"[A-Z0-9]{10}", requested):
            raise DevelopmentTeamError(
                "OESAP_DEVELOPMENT_TEAM must be the ten-character Apple Developer Team ID.")
        return requested
    try:
        certificates = subprocess.run(
            ["security", "find-certificate", "-a", "-c", "Apple Development", "-p"],
            capture_output=True, text=True, check=False, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise DevelopmentTeamError(
            "Could not inspect Apple Development certificate metadata. "
            "Set OESAP_DEVELOPMENT_TEAM or configure development signing in Xcode.") from error
    if certificates.returncode != 0:
        raise DevelopmentTeamError(
            "Apple Development certificates could not be read. "
            "Set OESAP_DEVELOPMENT_TEAM or configure development signing in Xcode.")
    pem_certificates = re.findall(
        r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
        certificates.stdout, re.DOTALL)
    teams: set[str] = set()
    for certificate in pem_certificates:
        try:
            subject = subprocess.run(
                ["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"],
                input=certificate, capture_output=True, text=True, check=False, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise DevelopmentTeamError("Could not read certificate subject metadata.") from error
        if subject.returncode == 0:
            distinguished_name = re.sub(r"^subject\s*=\s*", "", subject.stdout.strip())
            teams.update(re.findall(r"(?:^|,)\s*OU=([A-Z0-9]{10})(?=,|$)", distinguished_name))
    if len(teams) == 1:
        return next(iter(teams))
    if not teams:
        raise DevelopmentTeamError(
            "No Apple Development Team ID was found in local certificates. "
            "Configure an Apple Development certificate in Xcode, or set "
            "OESAP_DEVELOPMENT_TEAM explicitly. Mac builds require development signing for Keychain access.")
    raise DevelopmentTeamError(
        "Multiple Apple Development teams were found. Set OESAP_DEVELOPMENT_TEAM "
        "to choose the team that owns this app's development provisioning profile.")


def main() -> None:
    try:
        team = resolve_team(os.environ.get("OESAP_DEVELOPMENT_TEAM", ""))
    except DevelopmentTeamError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from error
    print(team)


if __name__ == "__main__":
    main()
