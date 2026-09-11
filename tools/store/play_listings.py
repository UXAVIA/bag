#!/usr/bin/env python3
"""
Push the Play Store listing text for every locale under fastlane/metadata/android/ to Google Play.

CI (r0adkll/upload-google-play) only uploads the bundle and the what's-new text; listing copy is
never synced by a release. This script is the missing half: one edit, one listings.update per
locale, committed at the end. With --images it also replaces the en-US phone screenshots and feature
graphic from the same fastlane folder (other locales fall back to en-US images on Play).

  tools/store/play_listings.py --sa KEY.json            # dry run: show what would change
  tools/store/play_listings.py --sa KEY.json --apply    # push
  tools/store/play_listings.py --sa KEY.json --apply --images   # also replace en-US screenshots + feature graphic

Prerequisite (once, Play Console → Users and permissions): invite the service account e-mail with
"Manage store presence" on Bag. Until then the API answers 403.

Run with the venv python that has the Google libs:
  /mnt/fedora-home/hannibalp/LocalRepos/pdf_blank_remove/tools/calibrate/.venv/bin/python
"""
from __future__ import annotations

import argparse
import socket
import sys
from pathlib import Path

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaFileUpload

PACKAGE = "app.bitbag"
ROOT = Path(__file__).resolve().parents[2]
META = ROOT / "fastlane" / "metadata" / "android"
LIMITS = {"title": 30, "short_description": 80, "full_description": 4000}


def prefer_ipv4() -> None:
    """This host has no working IPv6 route; Google's AAAA record comes first and hangs for two minutes."""
    orig = socket.getaddrinfo

    def ipv4_first(*args, **kwargs):
        res = orig(*args, **kwargs)
        return [r for r in res if r[0] == socket.AF_INET] or res

    socket.getaddrinfo = ipv4_first


def read_locales() -> dict[str, dict[str, str]]:
    out: dict[str, dict[str, str]] = {}
    for d in sorted(p for p in META.iterdir() if p.is_dir()):
        fields = {}
        for name in LIMITS:
            f = d / f"{name}.txt"
            if f.exists():
                fields[name] = f.read_text(encoding="utf-8").rstrip("\n")
        if fields:
            out[d.name] = fields
    return out


def check_limits(locales: dict[str, dict[str, str]]) -> None:
    bad = [(loc, k, len(v)) for loc, f in locales.items() for k, v in f.items() if len(v) > LIMITS[k]]
    if bad:
        for loc, k, n in bad:
            print(f"  {loc}/{k}: {n} chars > {LIMITS[k]}", file=sys.stderr)
        sys.exit("metadata exceeds Play limits; fix before pushing")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sa", required=True, help="service account JSON")
    ap.add_argument("--apply", action="store_true", help="commit the edit (default: dry run)")
    ap.add_argument("--images", action="store_true",
                    help="also replace en-US phoneScreenshots + featureGraphic from fastlane/metadata/android/en-US/images")
    args = ap.parse_args()

    prefer_ipv4()
    locales = read_locales()
    check_limits(locales)

    creds = service_account.Credentials.from_service_account_file(
        args.sa, scopes=["https://www.googleapis.com/auth/androidpublisher"])
    svc = build("androidpublisher", "v3", credentials=creds, cache_discovery=False)
    edits = svc.edits()

    try:
        edit_id = edits.insert(packageName=PACKAGE, body={}).execute()["id"]

        if args.images:
            img_dir = META / "en-US" / "images"
            shots = sorted(img_dir.glob("phoneScreenshots/*.png"), key=lambda p: int(p.stem))
            feature = img_dir / "featureGraphic.png"
            print(f"images: {len(shots)} phone screenshots, feature graphic {'yes' if feature.exists() else 'no'}")
            if args.apply:
                edits.images().deleteall(packageName=PACKAGE, editId=edit_id, language="en-US",
                                         imageType="phoneScreenshots").execute()
                for p in shots:
                    edits.images().upload(packageName=PACKAGE, editId=edit_id, language="en-US", imageType="phoneScreenshots",
                                          media_body=MediaFileUpload(str(p), mimetype="image/png")).execute()
                    print(f"  uploaded {p.name}")
                if feature.exists():
                    edits.images().deleteall(packageName=PACKAGE, editId=edit_id, language="en-US",
                                             imageType="featureGraphic").execute()
                    edits.images().upload(packageName=PACKAGE, editId=edit_id, language="en-US", imageType="featureGraphic",
                                          media_body=MediaFileUpload(str(feature), mimetype="image/png")).execute()
                    print("  uploaded featureGraphic.png")
        current = {l["language"]: l for l in
                   edits.listings().list(packageName=PACKAGE, editId=edit_id).execute().get("listings", [])}

        for lang, fields in locales.items():
            body = {"language": lang}
            if "title" in fields:
                body["title"] = fields["title"]
            if "short_description" in fields:
                body["shortDescription"] = fields["short_description"]
            if "full_description" in fields:
                body["fullDescription"] = fields["full_description"]
            cur = current.get(lang, {})
            changed = [k for k in ("title", "shortDescription", "fullDescription")
                       if k in body and body[k] != cur.get(k)]
            state = "new" if lang not in current else ("changed: " + ", ".join(changed) if changed else "unchanged")
            print(f"{lang:6s} {state}")
            if args.apply and (lang not in current or changed):
                edits.listings().update(packageName=PACKAGE, editId=edit_id, language=lang, body=body).execute()

        if args.apply:
            edits.commit(packageName=PACKAGE, editId=edit_id).execute()
            print("committed — Play reviews listing text within hours")
        else:
            edits.delete(packageName=PACKAGE, editId=edit_id).execute()
            print("dry run — nothing pushed (add --apply)")
    except HttpError as e:
        if e.resp.status == 403:
            sys.exit("403: the service account has no access to Bag in Play Console. "
                     "Users and permissions → invite it with 'Manage store presence'.")
        raise


if __name__ == "__main__":
    main()
