#!/usr/bin/env python3
"""Record explicitly approved owner observations, never infer physical acceptance."""
import argparse
import json
import os
from pathlib import Path
import tempfile
import time

from readiness import approval_binding, inspect_readiness


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "runtime-source", "hermes-home", "manifest", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--trusted-manifest-sha256", required=True)
    parser.add_argument("--origin", required=True)
    for name in ("phone-https-observed", "private-display-observed", "service-runtime-observed"):
        parser.add_argument("--" + name, action="store_true", required=True)
    args = parser.parse_args()
    report = inspect_readiness(args.hermes_home, args.runtime_source, source=args.source,
                              manifest=args.manifest, trusted_digest=args.trusted_manifest_sha256,
                              origin=args.origin)
    if not all(report[key] for key in ("issuer_ready", "runtime_matches", "home_matches",
                                      "https_origin_verified", "system_tls_trusted")):
        raise SystemExit("No observation recorded: source/runtime/trusted HTTPS prerequisites failed.")
    # An explicit path outside the checkout and profile is required, and its parent already exists.
    output = args.output.absolute()
    parent = output.parent.resolve(strict=True)
    if (output.exists() or output.is_symlink() or parent.is_relative_to(args.source.resolve())
            or parent.is_relative_to(args.hermes_home.resolve())):
        raise SystemExit("Choose a new private observation path outside source and Hermes home.")
    now = time.time()
    receipt = {"created_at": now, "expires_at": now + 600,
               "binding": approval_binding(args.hermes_home, args.runtime_source, report["origin"],
                                           args.trusted_manifest_sha256),
               "phone_https_observed": True, "private_display_observed": True,
               "service_runtime_observed": True}
    descriptor, temporary = tempfile.mkstemp(prefix=".fleet-observation-", dir=parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(receipt, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        # Link instead of replace refuses a concurrently created owner file.
        os.link(temporary, output)
    finally:
        os.unlink(temporary)
    print("Recorded owner observations for 10 minutes. Issuance still requires the actual private owner request.")


if __name__ == "__main__":
    main()
