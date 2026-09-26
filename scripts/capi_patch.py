#!/usr/bin/env python3
"""JSON merge patches for the CAPX cluster objects this factory owns."""

import argparse
import json
import re
import sys
from typing import Optional

_PREFIX = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:/-]*$")
_VERSION = re.compile(r"^v\d+\.\d+\.\d+$")


def prepare_command(prefix: str, version: str) -> str:
    if not _PREFIX.fullmatch(prefix):
        raise SystemExit(f"invalid image prefix: {prefix}")
    if not _VERSION.fullmatch(version):
        raise SystemExit(f"invalid kubernetes version: {version}")
    return f"prepare-capi-node --registry {prefix} --kubernetes-version {version}"


def _rolling(max_surge: int, max_unavailable: Optional[int]) -> dict:
    rolling = {"maxSurge": max_surge}
    if max_unavailable is not None:
        rolling["maxUnavailable"] = max_unavailable
    return {"type": "RollingUpdate", "rollingUpdate": rolling}


def kcp_patch(api_version: str, version: str, prefix: str) -> dict:
    cmd = prepare_command(prefix, version)
    spec = {
        "version": version,
        "kubeadmConfigSpec": {
            "clusterConfiguration": {"imageRepository": prefix},
            "preKubeadmCommands": [cmd],
        },
    }
    rollout = _rolling(0, None)
    if "v1beta1" in api_version:
        spec["rolloutStrategy"] = rollout
    else:
        spec["rollout"] = {"strategy": rollout}
    return {"spec": spec}


def md_patch(api_version: str, version: Optional[str]) -> dict:
    rollout = _rolling(0, 1)
    spec: dict = {}
    if version:
        spec["template"] = {"spec": {"version": version}}
    if "v1beta1" in api_version:
        spec["strategy"] = rollout
    else:
        spec["rollout"] = {"strategy": rollout}
    return {"spec": spec}


def kct_patch(prefix: str, version: str) -> dict:
    return {
        "spec": {
            "template": {
                "spec": {"preKubeadmCommands": [prepare_command(prefix, version)]}
            }
        }
    }


def main() -> None:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="kind", required=True)

    kcp = sub.add_parser("kcp")
    kcp.add_argument("--api-version", required=True)
    kcp.add_argument("--version", required=True)
    kcp.add_argument("--prefix", required=True)

    md = sub.add_parser("md")
    md.add_argument("--api-version", required=True)
    md.add_argument("--version")

    kct = sub.add_parser("kct")
    kct.add_argument("--prefix", required=True)
    kct.add_argument("--version", required=True)

    args = p.parse_args()
    if args.kind == "kcp":
        doc = kcp_patch(args.api_version, args.version, args.prefix)
    elif args.kind == "md":
        doc = md_patch(args.api_version, args.version)
    else:
        doc = kct_patch(args.prefix, args.version)
    json.dump(doc, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
