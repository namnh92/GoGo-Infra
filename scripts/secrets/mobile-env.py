#!/usr/bin/env python3
"""Render public mobile configuration; never request server signing/send secrets."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid
from urllib.parse import urlparse


FLAVORS = {"dev": "dev", "staging": "stag", "prod": "prod"}


def app_id(value):
    try:
        return str(uuid.UUID(value))
    except ValueError:
        raise ValueError("ONESIGNAL_APP_ID must be a UUID") from None


def https_url(value):
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("API/share URL must be HTTPS without credentials, query or fragment")
    return value.rstrip("/")


def mobile_values(environment, identifier, api_url, web_url, apns_mode):
    if environment not in FLAVORS or apns_mode not in ("development", "production"):
        raise ValueError("Invalid environment or APNs signing mode")
    return {
        "EXPO_PUBLIC_ENV": FLAVORS[environment],
        "EXPO_PUBLIC_API_URL": https_url(api_url),
        "EXPO_PUBLIC_WEB_BASE_URL": https_url(web_url),
        "ONESIGNAL_APP_ID": app_id(identifier),
        "ONESIGNAL_CONFIG_ENV": environment,
        "ONESIGNAL_APNS_MODE": apns_mode,
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
    command = ["aws", "ssm", "get-parameter", "--region", args.region, "--name", f"/gogo/{args.environment}/backend/onesignal/app-id", "--output", "json"]
    if args.profile:
        command += ["--profile", args.profile]
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    if result.returncode:
        parser.exit(1, "Cannot read this environment's OneSignal App ID from SSM; check AWS session/path.\n")
    try:
        identifier = json.loads(result.stdout)["Parameter"]["Value"]
        values = mobile_values(args.environment, identifier, args.api_url, args.web_url, args.apns_mode)
        write_env(args.out, values)
    except (ValueError, KeyError):
        parser.exit(1, "Invalid mobile configuration; no output updated.\n")
    print(f"Wrote {args.out}: {args.environment}, {len(values)} public variables, mode 0600")


if __name__ == "__main__":
    main()
