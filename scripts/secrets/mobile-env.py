#!/usr/bin/env python3
"""Render public mobile configuration; never request server signing/send secrets."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid
from urllib.parse import urlparse


# GoGo-Infra#286: the environment name *is* the mobile flavour (dev | stag | prod).
# No mapping table: max.gogo.<env> is the bundle id, and every provider config
# env (OneSignal, Adjust, Tenjin, Sentry) carries the same word.
FLAVORS = ("dev", "stag", "prod")


def app_id(value):
    try:
        return str(uuid.UUID(value))
    except ValueError:
        raise ValueError("ONESIGNAL_APP_ID must be a UUID") from None


# GoGo-Infra#208, ADR-0011. A Sentry DSN is config that ships in the binary, not
# a credential: its only power is to submit events to one project. The one other
# accepted value is the literal `off` — a single spelling, so a typo (`OFF`,
# `false`, `0`) cannot disable crash reporting on a store build by accident.
SENTRY_DSN = re.compile(r"^https://[A-Za-z0-9]+@[A-Za-z0-9.-]+/[0-9]+$")
SENTRY_OFF = "off"


def sentry_dsn(environment, value):
    """The value written as EXPO_PUBLIC_SENTRY_DSN, or ValueError.

    `value` is None when the SSM parameter does not exist. Only dev may build
    without one: a stag or production binary that silently reports nothing
    is found after it ships, and app.config.ts refuses the same build.
    """
    if value is None:
        if environment == "dev":
            return ""
        raise ValueError(f"/gogo/{environment}/mobile/sentry/dsn is required for {environment} builds")
    if value == SENTRY_OFF or SENTRY_DSN.match(value):
        return value
    raise ValueError("EXPO_PUBLIC_SENTRY_DSN must be a Sentry DSN (https://<key>@<host>/<project>) or the literal off")


# GoGo-Infra#237, GoGo-MobileApp#363 (MMP-001). An Adjust app token identifies
# one app in the Adjust dashboard and ships in the binary — config, not a
# credential, but kept SecureString like the Maps client keys. Adjust documents
# no format beyond a placeholder; the shape is the shape (rev 1) D4 contract,
# 8-32 letters and digits — the DEV tokens are 12 — so a six-character event
# token pasted in by mistake is refused.
# Same rule as the DSN: dev may build without one (Adjust off, warned);
# stag/prod need a token or the literal `off`, so a store build cannot drop
# its second MMP by omission.
ADJUST_TOKEN = re.compile(r"[A-Za-z0-9]{8,32}")
ADJUST_OFF = "off"
ADJUST_PLATFORMS = ("ios", "android")


def adjust_token(environment, platform, value):
    """The value written as ADJUST_<PLATFORM>_APP_TOKEN, or ValueError."""
    name = f"/gogo/{environment}/mobile/adjust/{platform}-app-token"
    if value is None:
        if environment == "dev":
            return ""
        raise ValueError(f"{name} is required for {environment} builds")
    if value == ADJUST_OFF or ADJUST_TOKEN.fullmatch(value):
        return value
    raise ValueError(f"ADJUST_{platform.upper()}_APP_TOKEN must be 8-32 letters and digits or the literal off")


# GoGo-Infra#291 (INF-MOB-2). The Tenjin SDK key per app and the Apple team id
# moved from config/bootstrap.env into SSM (mobile namespace). Same shape rules
# tenjin-mobile-env.py applies. For one release cycle an absent row is not an
# error: the file is written without it, a warning says so, and the old path
# (tenjin-mobile-env.py over bootstrap.env) fills it in. Half a Tenjin pair is
# a misconfiguration, not a fallback.
TENJIN_KEY = re.compile(r"[A-Za-z0-9_-]+")
TENJIN_PLATFORMS = ("ios", "android")
APPLE_TEAM = re.compile(r"[A-Z0-9]{10}")


def tenjin_values(environment, keys):
    """TENJIN_* for the file, {} when neither row exists, or ValueError."""
    present = {platform: value for platform, value in keys.items() if value is not None}
    if not present:
        return {}
    missing = [platform for platform in TENJIN_PLATFORMS if platform not in present]
    if missing:
        raise ValueError(f"/gogo/{environment}/mobile/tenjin/{missing[0]}-sdk-key is missing while the other platform's key exists")
    out = {}
    for platform in TENJIN_PLATFORMS:
        if not TENJIN_KEY.fullmatch(present[platform]):
            raise ValueError(f"TENJIN_{platform.upper()}_SDK_KEY must be letters, digits, - and _")
        out[f"TENJIN_{platform.upper()}_SDK_KEY"] = present[platform]
    out["TENJIN_CONFIG_ENV"] = environment
    return out


def apple_team_id(value):
    """APPLE_TEAM_ID for the file, {} when the row is absent, or ValueError."""
    if value is None:
        return {}
    if not APPLE_TEAM.fullmatch(value):
        raise ValueError("APPLE_TEAM_ID must be the 10-character Apple team id")
    return {"APPLE_TEAM_ID": value}


def https_url(value):
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("API/share URL must be HTTPS without credentials, query or fragment")
    return value.rstrip("/")


def mobile_values(environment, identifier, api_url, web_url, apns_mode, dsn="", adjust=None):
    if environment not in FLAVORS or apns_mode not in ("development", "production"):
        raise ValueError("Invalid environment or APNs signing mode")
    return {
        "EXPO_PUBLIC_ENV": environment,
        "EXPO_PUBLIC_API_URL": https_url(api_url),
        "EXPO_PUBLIC_WEB_BASE_URL": https_url(web_url),
        "ONESIGNAL_APP_ID": app_id(identifier),
        "ONESIGNAL_CONFIG_ENV": environment,
        "ONESIGNAL_APNS_MODE": apns_mode,
        "EXPO_PUBLIC_SENTRY_DSN": dsn,
        "ADJUST_IOS_APP_TOKEN": (adjust or {}).get("ios", ""),
        "ADJUST_ANDROID_APP_TOKEN": (adjust or {}).get("android", ""),
        "ADJUST_CONFIG_ENV": environment,
    }


def write_env(path, values):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".mobile-env-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write("# Generated public build config. No REST/signing keys. Do not commit.\n")
            for key, value in values.items():
                # Reject interpolation instead of emitting an executable dotenv value.
                if any(char in value for char in ('\n', '\r', '$', '`', '"', "'")):
                    raise ValueError(f"Unsupported character in {key}")
                handle.write(f"{key}={value}\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class ParameterMissing(Exception):
    pass


def read_parameter(args, name):
    """The parameter's value. ParameterMissing only when SSM says it does not
    exist; any other failure (session, permission) is not "absent" and stops."""
    # --with-decryption: the Adjust tokens are SecureString, and without it SSM
    # answers with the ciphertext (GoGo-Infra#237). Harmless for a String.
    command = ["aws", "ssm", "get-parameter", "--region", args.region, "--name", name, "--with-decryption", "--output", "json"]
    if args.profile:
        command += ["--profile", args.profile]
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    if result.returncode:
        if "ParameterNotFound" in result.stderr:
            raise ParameterMissing(name)
        raise RuntimeError(name)
    return json.loads(result.stdout)["Parameter"]["Value"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("environment", choices=FLAVORS)
    parser.add_argument("--profile")
    parser.add_argument("--region", default="ap-southeast-1")
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--web-url", required=True)
    parser.add_argument("--apns-mode", required=True, choices=["development", "production"], help="Signing channel, not GoGo environment: TestFlight uses production even for DEV")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    try:
        identifier = read_parameter(args, f"/gogo/{args.environment}/backend/onesignal/app-id")
    except (ParameterMissing, RuntimeError, ValueError, KeyError):
        parser.exit(1, "Cannot read this environment's OneSignal App ID from SSM; check AWS session/path.\n")
    try:
        raw_dsn = read_parameter(args, f"/gogo/{args.environment}/mobile/sentry/dsn")
    except ParameterMissing:
        raw_dsn = None
    except (RuntimeError, ValueError, KeyError):
        parser.exit(1, "Cannot read this environment's Sentry DSN from SSM; check AWS session/path.\n")
    raw_adjust = {}
    for platform in ADJUST_PLATFORMS:
        try:
            raw_adjust[platform] = read_parameter(args, f"/gogo/{args.environment}/mobile/adjust/{platform}-app-token")
        except ParameterMissing:
            raw_adjust[platform] = None
        except (RuntimeError, ValueError, KeyError):
            parser.exit(1, "Cannot read this environment's Adjust app tokens from SSM; check AWS session/path.\n")
    raw_tenjin = {}
    for platform in TENJIN_PLATFORMS:
        try:
            raw_tenjin[platform] = read_parameter(args, f"/gogo/{args.environment}/mobile/tenjin/{platform}-sdk-key")
        except ParameterMissing:
            raw_tenjin[platform] = None
        except (RuntimeError, ValueError, KeyError):
            parser.exit(1, "Cannot read this environment's Tenjin SDK keys from SSM; check AWS session/path.\n")
    try:
        raw_team = read_parameter(args, f"/gogo/{args.environment}/mobile/apple/team-id")
    except ParameterMissing:
        raw_team = None
    except (RuntimeError, ValueError, KeyError):
        parser.exit(1, "Cannot read this environment's Apple team id from SSM; check AWS session/path.\n")
    try:
        dsn = sentry_dsn(args.environment, raw_dsn)
        adjust = {platform: adjust_token(args.environment, platform, value) for platform, value in raw_adjust.items()}
        values = mobile_values(args.environment, identifier, args.api_url, args.web_url, args.apns_mode, dsn, adjust)
        values.update(tenjin_values(args.environment, raw_tenjin))
        values.update(apple_team_id(raw_team))
        write_env(args.out, values)
    except ValueError as error:
        parser.exit(1, f"Invalid mobile configuration ({error}); no output updated.\n")
    except KeyError:
        parser.exit(1, "Invalid mobile configuration; no output updated.\n")
    if raw_dsn is None:
        print("warning: no Sentry DSN for dev; crash reporting is off in this build", file=sys.stderr)
    for platform, value in raw_adjust.items():
        if value is None:
            print(f"warning: no Adjust {platform} app token for dev; Adjust is off on {platform} in this build", file=sys.stderr)
    if all(value is None for value in raw_tenjin.values()):
        print(f"warning: no Tenjin SDK keys in SSM for {args.environment} (GoGo-Infra#291); fill them with tenjin-mobile-env.py from bootstrap.env until put.sh writes them", file=sys.stderr)
    if raw_team is None:
        print(f"warning: no Apple team id in SSM for {args.environment} (GoGo-Infra#291); APPLE_TEAM_ID is not in this file", file=sys.stderr)
    print(f"Wrote {args.out}: {args.environment}, {len(values)} public variables, mode 0600")


if __name__ == "__main__":
    main()
