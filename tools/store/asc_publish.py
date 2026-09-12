#!/usr/bin/env python3
"""
App Store Connect metadata + screenshots for Bag, straight from fastlane/metadata/ios/<locale>/.

Why this exists next to `deliver`: deliver runs only inside the release workflow (and with skip_screenshots),
so between releases nothing can stage a new version's listing. This script creates the next version if
needed, writes every locale's app-info (name, subtitle) and version (description, keywords, promo,
what's new) localisations, and uploads the 6.9" screenshots. A later `deliver` run for the same version
simply overwrites the text with the same files — the two never disagree because both read the same folder.

  tools/store/asc_publish.py status
  tools/store/asc_publish.py metadata --version 1.3.3 [--dry-run]      # all locales, creates the version if missing
  tools/store/asc_publish.py screenshots --version 1.3.3 [--dir store-assets/ios] [--display APP_IPHONE_67]
  tools/store/asc_publish.py promo                                     # promotional text on the LIVE version (the one field Apple lets you edit live)

Auth: env ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH or the --key-* flags (no defaults — this file ships in the public
source snapshot; the team key id/issuer live in ~/.secrets/aerocommute/key_issuer_id.txt, the .p8 next to it).
Run with the venv python that has PyJWT + requests: pdf_blank_remove/tools/calibrate/.venv/bin/python
"""
from __future__ import annotations

import argparse
import hashlib
import os
import socket
import sys
import time
from pathlib import Path

import jwt
import requests

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "app.bitbag"
APP_NAME = "Bag: Bitcoin Portfolio Monitor"   # not localised — brand stays identical in every storefront
ROOT = Path(__file__).resolve().parents[2]
META = ROOT / "fastlane" / "metadata" / "ios"
EDITABLE_STATES = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")
LIMITS = {"name": 30, "subtitle": 30, "keywords": 100, "promotionalText": 170, "description": 4000, "whatsNew": 4000}

# Used when a locale folder has no release_notes.txt (CI only writes en-US). Apple requires What's New on every
# localisation of an update, so a generic, truthful line beats a submission error.
DEFAULT_WHATS_NEW = {
    "en-US": "Store listing in nine languages, new screenshots, and a one-time rating prompt.",
    "de-DE": "Store-Eintrag in neun Sprachen, neue Screenshots und eine einmalige Bewertungsanfrage.",
    "fr-FR": "Fiche en neuf langues, nouvelles captures d'écran et une seule demande d'évaluation.",
    "es-ES": "Ficha en nueve idiomas, nuevas capturas de pantalla y una única solicitud de valoración.",
    "it": "Scheda in nove lingue, nuovi screenshot e una sola richiesta di valutazione.",
    "pt-BR": "Página em nove idiomas, novas capturas de tela e um único pedido de avaliação.",
    "nl-NL": "Winkelvermelding in negen talen, nieuwe schermafbeeldingen en één beoordelingsverzoek.",
    "pl": "Opis w dziewięciu językach, nowe zrzuty ekranu i jednorazowa prośba o ocenę.",
    "ja": "9言語のストア掲載、新しいスクリーンショット、1回だけの評価のお願い。",
}


def prefer_ipv4() -> None:
    """This host has no working IPv6 route; Apple's AAAA record comes first and hangs."""
    orig = socket.getaddrinfo

    def ipv4_first(*args, **kwargs):
        res = orig(*args, **kwargs)
        return [r for r in res if r[0] == socket.AF_INET] or res

    socket.getaddrinfo = ipv4_first


class Asc:
    def __init__(self, key_id: str, issuer: str, key_path: str):
        self.key_id, self.issuer, self.key = key_id, issuer, Path(key_path).read_text()
        self._tok, self._exp = None, 0

    def token(self) -> str:
        if time.time() > self._exp - 60:
            now = int(time.time())
            self._exp = now + 1200
            self._tok = jwt.encode({"iss": self.issuer, "iat": now, "exp": self._exp, "aud": "appstoreconnect-v1"},
                                   self.key, algorithm="ES256", headers={"kid": self.key_id})
        return self._tok

    def req(self, method: str, path: str, **kw):
        url = path if path.startswith("http") else API + path
        r = requests.request(method, url, headers={"Authorization": f"Bearer {self.token()}",
                                                   "Content-Type": "application/json"}, timeout=60, **kw)
        if r.status_code >= 400:
            try:
                errs = "; ".join(f"{e.get('code')}: {e.get('detail')}" for e in r.json().get("errors", []))
            except Exception:
                errs = r.text[:300]
            raise RuntimeError(f"{method} {path} → {r.status_code} {errs}")
        return r.json() if r.content and r.status_code != 204 else {}

    def get(self, path, **kw): return self.req("GET", path, **kw)
    def post(self, path, data): return self.req("POST", path, json={"data": data})
    def patch(self, path, data): return self.req("PATCH", path, json={"data": data})
    def delete(self, path): return self.req("DELETE", path)


def app_id(asc: Asc) -> str:
    apps = asc.get(f"/v1/apps?filter[bundleId]={BUNDLE_ID}&fields[apps]=name,bundleId")["data"]
    if not apps:
        sys.exit(f"{BUNDLE_ID} is not visible to this API key")
    return apps[0]["id"]


def versions(asc: Asc, aid: str) -> list[dict]:
    return asc.get(f"/v1/apps/{aid}/appStoreVersions?filter[platform]=IOS&limit=20"
                   "&fields[appStoreVersions]=versionString,appStoreState,releaseType")["data"]


def find_or_create_version(asc: Asc, aid: str, version: str, dry: bool) -> dict | None:
    for v in versions(asc, aid):
        if v["attributes"]["versionString"] == version:
            return v
    if dry:
        print(f"  [dry-run] would create App Store version {version}")
        return None
    v = asc.post("/v1/appStoreVersions", {"type": "appStoreVersions",
                                          "attributes": {"platform": "IOS", "versionString": version, "releaseType": "AFTER_APPROVAL"},
                                          "relationships": {"app": {"data": {"type": "apps", "id": aid}}}})["data"]
    print(f"  created App Store version {version} (PREPARE_FOR_SUBMISSION)")
    return v


def read(locale: str, name: str) -> str | None:
    f = META / locale / f"{name}.txt"
    return f.read_text(encoding="utf-8").rstrip("\n") if f.exists() else None


def locales() -> list[str]:
    return sorted(p.name for p in META.iterdir() if p.is_dir() and (p / "description.txt").exists())


def _upsert(asc: Asc, list_path: str, type_: str, parent_rel: str, parent_id: str, locale: str, attrs: dict, dry: bool) -> None:
    attrs = {k: v for k, v in attrs.items() if v is not None}
    for k, v in attrs.items():
        if k in LIMITS and len(v) > LIMITS[k]:
            sys.exit(f"{locale}/{k}: {len(v)} chars > {LIMITS[k]}")
    existing = {l["attributes"]["locale"]: l for l in asc.get(list_path)["data"]}
    verb = "update" if locale in existing else "create"
    if dry:
        print(f"  [dry-run] {verb} {type_} {locale}: " + ", ".join(f"{k}={len(v)}ch" for k, v in attrs.items()))
        return
    if locale in existing:
        lid = existing[locale]["id"]
        asc.patch(f"/v1/{type_}/{lid}", {"type": type_, "id": lid, "attributes": attrs})
    else:
        asc.post(f"/v1/{type_}", {"type": type_, "attributes": {"locale": locale, **attrs},
                                  "relationships": {parent_rel: {"data": {"type": parent_rel + "s", "id": parent_id}}}})
    print(f"  {verb} {type_} {locale}")


# ------------------------------------------------------------------------------------------------ commands

def cmd_status(asc: Asc, args) -> None:
    aid = app_id(asc)
    for v in versions(asc, aid)[:5]:
        a = v["attributes"]
        print(f"{a['versionString']:8s} {a['appStoreState']}")
    infos = asc.get(f"/v1/apps/{aid}/appInfos?fields[appInfos]=appStoreState")["data"]
    for i in infos:
        locs = asc.get(f"/v1/appInfos/{i['id']}/appInfoLocalizations")["data"]
        print(f"appInfo {i['attributes']['appStoreState']}: " +
              ", ".join(f"{l['attributes']['locale']}={l['attributes'].get('subtitle')!r}" for l in locs))
    print("fastlane locales:", ", ".join(locales()))


def cmd_metadata(asc: Asc, args) -> None:
    aid = app_id(asc)
    v = find_or_create_version(asc, aid, args.version, args.dry_run)
    if v and v["attributes"]["appStoreState"] not in EDITABLE_STATES:
        sys.exit(f"version {args.version} is {v['attributes']['appStoreState']} — not editable")
    infos = asc.get(f"/v1/apps/{aid}/appInfos?fields[appInfos]=appStoreState")["data"]
    info = next((i for i in infos if i["attributes"]["appStoreState"] in EDITABLE_STATES), None)
    if info is None and not args.dry_run:
        sys.exit("no editable appInfo (create the version first)")
    privacy_url = None
    if info:
        cur = asc.get(f"/v1/appInfos/{info['id']}/appInfoLocalizations")["data"]
        privacy_url = next((l["attributes"].get("privacyPolicyUrl") for l in cur if l["attributes"]["locale"] == "en-US"), None)
    support_url, marketing_url = read("en-US", "support_url"), read("en-US", "marketing_url")

    for loc in locales():
        print(loc)
        if info:
            _upsert(asc, f"/v1/appInfos/{info['id']}/appInfoLocalizations", "appInfoLocalizations", "appInfo", info["id"], loc,
                    {"name": APP_NAME, "subtitle": read(loc, "subtitle"), "privacyPolicyUrl": privacy_url}, args.dry_run)
        if v:
            _upsert(asc, f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations", "appStoreVersionLocalizations",
                    "appStoreVersion", v["id"], loc,
                    {"description": read(loc, "description"), "keywords": read(loc, "keywords"),
                     "promotionalText": read(loc, "promotional_text"),
                     "whatsNew": read(loc, "release_notes") or DEFAULT_WHATS_NEW.get(loc),
                     "supportUrl": support_url, "marketingUrl": marketing_url}, args.dry_run)


def cmd_promo(asc: Asc, args) -> None:
    """Promotional text is the one version field Apple lets you change on a live version."""
    aid = app_id(asc)
    live = next((v for v in versions(asc, aid) if v["attributes"]["appStoreState"] == "READY_FOR_SALE"), None)
    if live is None:
        sys.exit("no live version")
    for loc in locales():
        promo = read(loc, "promotional_text")
        if not promo:
            continue
        existing = {l["attributes"]["locale"]: l for l in
                    asc.get(f"/v1/appStoreVersions/{live['id']}/appStoreVersionLocalizations")["data"]}
        if loc not in existing:
            print(f"  {loc}: not on the live version, skipped")
            continue
        if args.dry_run:
            print(f"  [dry-run] {loc}: {promo}")
            continue
        lid = existing[loc]["id"]
        asc.patch(f"/v1/appStoreVersionLocalizations/{lid}",
                  {"type": "appStoreVersionLocalizations", "id": lid, "attributes": {"promotionalText": promo}})
        print(f"  {loc}: promotional text updated on live {live['attributes']['versionString']}")


def cmd_screenshots(asc: Asc, args) -> None:
    aid = app_id(asc)
    v = find_or_create_version(asc, aid, args.version, False)
    if v["attributes"]["appStoreState"] not in EDITABLE_STATES:
        sys.exit(f"version {args.version} is {v['attributes']['appStoreState']} — not editable")
    locs = asc.get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations")["data"]
    loc = next((l for l in locs if l["attributes"]["locale"] == args.locale), None)
    if not loc:
        sys.exit(f"run `metadata --version {args.version}` first (no {args.locale} version localization)")
    sets = asc.get(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]
    sset = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == args.display), None)
    if sset is None:
        sset = asc.post("/v1/appScreenshotSets", {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": args.display},
                        "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}})["data"]
    files = sorted(p for p in Path(args.dir).glob("*.png") if p.is_file())
    if not files:
        sys.exit(f"no screenshots in {args.dir}")
    for old in asc.get(f"/v1/appScreenshotSets/{sset['id']}/appScreenshots")["data"]:
        asc.delete(f"/v1/appScreenshots/{old['id']}")
    for f in files[:10]:
        data = f.read_bytes()
        res = asc.post("/v1/appScreenshots", {"type": "appScreenshots", "attributes": {"fileName": f.name, "fileSize": len(data)},
                       "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": sset["id"]}}}})["data"]
        for op in res["attributes"]["uploadOperations"]:
            chunk = data[op["offset"]: op["offset"] + op["length"]]
            r = requests.request(op["method"], op["url"], headers={h["name"]: h["value"] for h in op["requestHeaders"]}, data=chunk, timeout=120)
            r.raise_for_status()
        asc.patch(f"/v1/appScreenshots/{res['id']}", {"type": "appScreenshots", "id": res["id"],
                  "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}})
        print(f"  uploaded {f.name}")
    print(f"screenshots: {min(len(files), 10)} in {args.display} for {args.locale} on {args.version}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["status", "metadata", "promo", "screenshots"])
    ap.add_argument("--version", help="App Store version string (metadata/screenshots)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--dir", default=str(ROOT / "store-assets" / "ios"))
    ap.add_argument("--display", default="APP_IPHONE_67", help="6.9\"/6.7\" set; accepts 1290×2796 and 1320×2868")
    ap.add_argument("--locale", default="en-US", help="screenshots: locale to upload to (others fall back to the primary)")
    ap.add_argument("--key-id", default=os.environ.get("ASC_KEY_ID"))
    ap.add_argument("--issuer-id", default=os.environ.get("ASC_ISSUER_ID"))
    ap.add_argument("--key-path", default=os.environ.get("ASC_KEY_PATH"))
    args = ap.parse_args()
    if args.command in ("metadata", "screenshots") and not args.version:
        sys.exit("--version is required")
    if not (args.key_id and args.issuer_id and args.key_path):
        sys.exit("set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (see ~/.secrets/<team>/key_issuer_id.txt) or pass --key-*")
    prefer_ipv4()
    asc = Asc(args.key_id, args.issuer_id, args.key_path)
    {"status": cmd_status, "metadata": cmd_metadata, "promo": cmd_promo, "screenshots": cmd_screenshots}[args.command](asc, args)


if __name__ == "__main__":
    main()
