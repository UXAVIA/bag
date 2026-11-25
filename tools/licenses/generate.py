#!/usr/bin/env python3
"""Bag's third-party licence notices, generated from what the build uses.

    bash tools/licenses/generate.sh

Writes three files, all committed:
  assets/licenses/rust_licenses.json    the Rust crates compiled into the tor
                                        plugin's native library (librust_lib_tor)
                                        and the C sources bundled in them;
  assets/licenses/native_licenses.json  the Android libraries the app and its
                                        plugins pull in (and the iOS check);
  THIRD_PARTY_NOTICES.md                both, plus the Dart packages, for the
                                        public source tree.
The app registers the two assets on its licence page
(lib/core/licenses/register_licenses.dart); Flutter registers the Dart
packages and its engine there itself.

Needs network (cargo fetches crates, pub resolves the store flavor, the
Android libraries' POMs come from Google's Maven and Maven Central), and:
  - the Flutter release in .flutter-version, on PATH;
  - cargo, and cargo-about at CARGO_ABOUT_VERSION:
        cargo install --locked --features cli cargo-about --version 0.9.3
Run with `python3 -I` (generate.sh does). Standard library only.

How each part is enumerated:
  - Rust: `cargo about generate --frozen` over the fork's rust/Cargo.toml at
    the commit pubspec.lock pins, with tools/licenses/about.toml (accepted
    licences, the four shipped targets). `cargo tree` per target says which
    platform each crate is built for. C sources bundled in a crate, and
    licence files a crate's package lacks, come from tools/licenses/
    curated.json, pinned by SHA-256.
  - Android: each runtime plugin's android/build.gradle(.kts), the app's
    android/app/build.gradle.kts and the Flutter Android embedding's own list
    (FLUTTER_ROOT/engine/src/flutter/tools/androidx/files.json) give the
    declared libraries; the Kotlin Gradle plugin adds kotlin-stdlib to every
    Kotlin module. Their transitive runtime dependencies are read from the
    libraries' POMs, the highest requested version winning as in Gradle.
    That is an approximation of Gradle's resolution (exclusions and Gradle
    module metadata are not applied, so it errs towards listing more).
  - Store flavor: CI adds in_app_purchase and in_app_review before building
    for Play and the App Store. This resolves them the same way in a scratch
    copy and marks what only that build has.
  - iOS: every runtime plugin's podspec and Package.swift; any dependency
    other than Flutter fails generation until it is classified here.
  - Dart: the runtime closure of `flutter pub deps --json` (no
    dev_dependencies) and each package's LICENSE file, which is what
    Flutter itself shows in the app.

Generation fails, rather than guessing, when a licence isn't accepted or
can't be classified, when curated data no longer matches the files it pins,
or when a proprietary library would reach the direct (F-Droid) build.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
ABOUT_TOML = HERE / "about.toml"
CURATED = HERE / "curated.json"
RUST_JSON = REPO / "assets" / "licenses" / "rust_licenses.json"
NATIVE_JSON = REPO / "assets" / "licenses" / "native_licenses.json"
NOTICES_MD = REPO / "THIRD_PARTY_NOTICES.md"

# The pinned cargo-about. The release workflow installs this version (its own
# check keeps the two equal).
CARGO_ABOUT_VERSION = "0.9.3"

# about.toml's `accepted`, in the same order (checked at run time).
ACCEPTED = (
    "MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Zlib",
    "Unicode-3.0", "CC0-1.0", "Unlicense", "MPL-2.0",
)
# The Rust targets Bag ships, which about.toml's `targets` must equal.
RUST_TARGETS = (
    "aarch64-apple-ios", "aarch64-linux-android", "armv7-linux-androideabi",
    "x86_64-linux-android",
)
# Crates that exist only for platforms Bag doesn't ship. Seeing one means the
# target filter failed.
FOREIGN_CRATE = re.compile(r"^(?:r-efi|windows(?:[-_].*)?|wasi(?:x|p\d+)?(?:[-_].*)?|wasm-bindgen.*|js-sys|web-sys)$")
# What the release workflow adds for the store flavor (Google Play and the App
# Store) with `dart pub add`, in this order. Every package of the in-app
# purchase and rating plugins is pinned exactly, transitive ones included, so
# the store build and these notices resolve the same versions
# (in_app_purchase_android 0.5.0 bundles Play Billing Library 8.0.0).
STORE_PACKAGES = (
    "in_app_purchase:3.3.1", "in_app_purchase_android:0.5.0",
    "in_app_purchase_platform_interface:1.4.1", "in_app_purchase_storekit:0.4.17",
    "in_app_review:2.0.12", "in_app_review_platform_interface:2.0.5",
)
# Dart LICENSE files may contain any of these, plus 0BSD for bundled C code.
DART_ACCEPTED = set(ACCEPTED) | {"0BSD"}
# Build dependencies that compile C or C++ into a crate.
NATIVE_BUILD_DEPS = {"cc", "cmake", "autotools"}
# Maven repositories, in the order the app's Gradle build lists them.
MAVEN_REPOS = ("https://dl.google.com/android/maven2", "https://repo.maven.apache.org/maven2")
POM_CACHE = REPO / "build" / "licenses" / "maven"
# Files in a crate's package directory: its licence texts, and notices that
# go with them (Apache-2.0 NOTICE files, the Rust projects' COPYRIGHT files).
LICENCE_FILE = re.compile(r"(?i)^(?:licen[cs]e|copying)(?:[-._].*)?$")
NOTICE_FILE = re.compile(r"(?i)^(?:notice|copyright)(?:[-._].*)?$")
# Files holding other projects' notices, for code a crate took in
# (LICENSE-THIRD-PARTY, THIRD_PARTY …). Each one needs a reviewed entry in
# curated.json reviewed_files; they are never read as the crate's own.
THIRD_PARTY_FILE = re.compile(r"(?i)third[-_ .]?part(?:y|ies)")
# Licence-named files anywhere in a package below its root (Unicode tables'
# LICENSE-UNICODE, a vendored module's LICENSE, COPYRIGHT, UNLICENSE or
# PATENTS …) must be reviewed too.
NESTED_LICENCE_FILE = re.compile(
    r"(?i)^(?:licen[cs]e|copying|notice|copyright|unlicense|patents)(?:[-._].*)?$|third[-_ .]?part(?:y|ies)"
)
# Directories whose files aren't compiled into a library.
UNCOMPILED_DIRS = {"tests", "test", "examples", "example", "benches", "bench", "docs", "doc"}
# A copyright line nobody filled in, as licence templates have them
# (`Copyright (c) <year> <copyright holders>`, `[year] [fullname]`,
# `{yyyy} {name}`).
PLACEHOLDER = re.compile(
    r"<\s*(?:year|yyyy|copyright holders?|owner|fullname|name of [^>]*)\s*>"
    r"|\[\s*(?:yyyy|year|fullname|owner)\s*\]"
    r"|\{\s*(?:yyyy|year|copyright holders?|owner|fullname|name|name of [^}]*)\s*\}",
    re.I,
)
# Where an Apache License text's terms end. The appendix after it tells
# authors how to apply the licence, with its own `[yyyy] [name of copyright
# owner]`: licence text, not a placeholder of the package's.
END_OF_TERMS = "END OF TERMS AND CONDITIONS"
# A line opening with a copyright statement: the word followed by (c) or ©,
# by a year (bracketed too, as in an Apache appendix filled in without
# removing its brackets: memmap2's `Copyright [2015] [Dan Burkert]`), or
# (`Copyright Google`) by a capitalised name. A licence's own sentences don't
# count: `copyright notice that is included …` is lower case, `COPYRIGHT AND
# PERMISSION NOTICE` has none of those, and an Apache clause `(c) You must …`
# has no year.
COPYRIGHT_LINE = re.compile(
    r"^\s*(?:"
    r"(?:Copyright|COPYRIGHT|©)\s*(?:\([cC]\)|©)\s*\S"
    r"|(?:Copyright|COPYRIGHT|©|\([cC]\))\s*(?:\[\s*)?\d{4}"
    r"|Copyright\s+(?!(?:and|And|AND|Notice|NOTICE|notice|License|Licence|LICENSE|Holders?|HOLDERS?|Owners?|"
    r"Law|Act|Similar|Related|Rights)\b)[A-Z]"
    r")",
    re.M,
)
# A copyright statement further along a line, its year (bracketed or not)
# right after the word or opening the next line: hashlink's MIT text says
# "derived in part from the `linked-hash-map` crate, Copyright (c)" / "2015
# The Rust Project Developers". Derived-work holders count, as parking's do.
MIDLINE_COPYRIGHT = re.compile(r"(?:\bCopyright\b|\bCOPYRIGHT\b|©)(?:\s*(?:\([cC]\)|©))?\s*(?=(?:\[\s*)?\d{4}\b|$)")
# A year opening a line, bracketed or not.
YEAR_FIRST = re.compile(r"^\s*(?:\[\s*)?\d{4}\b")
TOR_PACKAGE = "tor"
TOR_CRATE = "rust_lib_tor"
PUB_DEV = "https://pub.dev/packages"


class Failure(Exception):
    """A reason the notices can't be generated as they stand."""


# ── Small helpers ────────────────────────────────────────────────────────────


def run(cmd, cwd=None, env=None):
    """`cmd`'s stdout; a Failure with its output when it exits non-zero."""
    proc = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    if proc.returncode != 0:
        raise Failure(f"`{' '.join(cmd)}` failed ({proc.returncode}):\n{proc.stdout}{proc.stderr}")
    return proc.stdout


def sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read_text(path):
    """A licence file's text with Windows line endings normalised."""
    return Path(path).read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")


def curated_text(curated, key):
    entry = curated["texts"][key]
    text = read_text(HERE / entry["file"])
    if sha256(text) != entry["sha256"]:
        raise Failure(f"tools/licenses/{entry['file']} no longer has the SHA-256 curated.json pins")
    return text


def terms_of(text):
    """`text` up to the end of an Apache License's terms (all of any other)."""
    return text.split(END_OF_TERMS, 1)[0]


def placeholder_copyright(line):
    """Whether `line` is a template copyright line nobody filled in
    (`Copyright (c) <year> <copyright holders>`). A placeholder elsewhere,
    such as a template's `<COPYRIGHT HOLDER>` left in a disclaimer, is
    licence text and stays."""
    return bool(re.match(r"^\s*(?:Copyright|COPYRIGHT|©|\([cC]\))", line) and PLACEHOLDER.search(line))


def strip_placeholders(text):
    """`text` without template copyright lines nobody filled in (outside an
    Apache appendix), and whether any were dropped."""
    terms = terms_of(text)
    kept = [line for line in terms.splitlines(keepends=True) if not placeholder_copyright(line)]
    if len(kept) == len(terms.splitlines(keepends=True)):
        return text, False
    stripped = re.sub(r"\n{3,}", "\n\n", "".join(kept).lstrip("\n"))
    return stripped + text[len(terms):], True


def names_a_holder(statement):
    """Whether a copyright statement names someone: not a template nobody
    filled in, and not a licence document's own (the GPL family's `Copyright
    (C) 2007 Free Software Foundation, Inc.` is about the licence text)."""
    return not PLACEHOLDER.search(statement) and "Free Software Foundation" not in statement


def copyright_statements(text):
    """The copyright statements in `text` that name a holder. One opening a
    line keeps the indented lines that continue it with another year
    (`Copyright 2011-2017 Google Inc.` / `          2013 Jack Lloyd`); one
    further along a line runs from the word to the line's end, joined with the
    next line when its year opens that line."""
    statements, lines = [], text.splitlines()
    for i, line in enumerate(lines):
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        if COPYRIGHT_LINE.match(line):
            block = [line.strip()]
            for more in lines[i + 1:]:
                if not re.match(r"^\s+\d{4}\b", more):
                    break
                block.append(more.rstrip())
            statement = "\n".join(block)
        else:
            mid = MIDLINE_COPYRIGHT.search(line)
            if not mid:
                continue
            statement = line[mid.start():].strip()
            if not re.search(r"\d{4}", statement):
                if not YEAR_FIRST.match(nxt):
                    continue
                statement += " " + nxt.strip()
        if names_a_holder(statement):
            statements.append(statement)
    return statements


def has_copyright_line(texts):
    """Whether any of `texts` names a copyright holder (an Apache appendix
    filled in by the author counts)."""
    return any(copyright_statements(text) for text in texts)


class Texts:
    """Licence texts, each stored once and referred to by index."""

    def __init__(self):
        self.items, self.index = [], {}

    def add(self, text):
        if text not in self.index:
            self.index[text] = len(self.items)
            self.items.append(text)
        return self.index[text]


# ── Licence text classification (Dart LICENSE files) ─────────────────────────


def normalise(text):
    text = text.lower().replace("’", "'").replace("“", '"').replace("”", '"')
    return " " + " ".join(re.sub(r"[^a-z0-9]+", " ", text).split()) + " "


# Each licence: alternatives, each a list of phrases that must all appear.
FINGERPRINTS = (
    ("Apache-2.0", (("apache license", "version 2 0"),)),
    ("MPL-2.0", (("mozilla public license version 2 0",), ("mozilla public license v 2 0",))),
    ("MIT", (("permission is hereby granted free of charge to any person obtaining a copy",
              "the above copyright notice and this permission notice shall be included"),)),
    ("BSD-3-Clause", (("redistribution and use in source and binary forms with or without modification are permitted",
                       "neither the name of"),
                      ("redistribution and use in source and binary forms with or without modification are permitted",
                       "the names of its contributors may not be used to endorse"),)),
    ("BSD-2-Clause", (("redistribution and use in source and binary forms with or without modification are permitted",
                       "redistributions in binary form must reproduce"),)),
    ("ISC", (("permission to use copy modify and or distribute this software for any purpose with or without fee is hereby granted provided that the above copyright notice and this permission notice appear in all copies",),)),
    ("0BSD", (("permission to use copy modify and or distribute this software for any purpose with or without fee is hereby granted the software is provided as is",),)),
    ("Zlib", (("this software is provided as is without any express or implied warranty",
               "altered source versions must be plainly marked"),)),
    ("Unlicense", (("this is free and unencumbered software released into the public domain",),)),
    ("CC0-1.0", (("creative commons", "cc0 1 0"),)),
    # Copyleft licences Bag can't take, by their titles or their usual notice.
    # (The MPL's own text names the GPLs without their titles.)
    ("GPL", (("gnu general public license version 2 june 1991",),
             ("gnu general public license version 3 29 june 2007",),
             ("gnu lesser general public license version 2 1 february 1999",),
             ("gnu lesser general public license version 3 29 june 2007",),
             ("gnu affero general public license version 3 19 november 2007",),
             ("you can redistribute it and or modify it under the terms of the gnu",))),
)


def classify(text):
    """The licences whose fingerprints `text` contains, in a fixed order."""
    norm = normalise(text)
    found = [
        lid for lid, alternatives in FINGERPRINTS
        if any(all(f" {phrase} " in norm for phrase in alt) for alt in alternatives)
    ]
    if "BSD-3-Clause" in found and "BSD-2-Clause" in found:
        found.remove("BSD-2-Clause")
    if "ISC" in found and "0BSD" in found:
        found.remove("0BSD")
    return found


# ── Flutter and pub ──────────────────────────────────────────────────────────


def flutter_info():
    pinned = (REPO / ".flutter-version").read_text().strip()
    info = json.loads(run(["flutter", "--version", "--machine"]))
    if info.get("frameworkVersion") != pinned:
        raise Failure(
            f"Flutter is {info.get('frameworkVersion')}, but .flutter-version pins {pinned}: "
            "the Dart and Flutter-embedding parts of the notices depend on it."
        )
    return pinned, Path(info["flutterRoot"])


def package_roots(project):
    """{package: root dir} from <project>/.dart_tool/package_config.json."""
    config_path = project / ".dart_tool" / "package_config.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    roots = {}
    for package in config["packages"]:
        uri = package["rootUri"]
        if uri.startswith("file:"):
            roots[package["name"]] = Path(urllib.parse.unquote(urllib.parse.urlparse(uri).path))
        else:
            roots[package["name"]] = (config_path.parent / urllib.parse.unquote(uri)).resolve()
    return roots


def pub_graph(project):
    """(root name, {package: entry}) from `flutter pub deps --json`."""
    deps = json.loads(run(["flutter", "pub", "deps", "--json"], cwd=project))
    return deps["root"], {p["name"]: p for p in deps["packages"]}


def runtime_closure(root, packages):
    """Every package the root's non-dev dependencies reach."""
    seen, stack = set(), list(packages[root]["directDependencies"])
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        stack.extend(packages[name]["dependencies"])
    return seen


def resolve_store_flavor(workdir):
    """A scratch copy of the app resolved as the release workflow resolves the
    store flavor (every package pinned exactly, so in one command)."""
    store = workdir / "store"
    store.mkdir()
    for name in ("pubspec.yaml", "pubspec.lock"):
        shutil.copy2(REPO / name, store / name)
    run(["dart", "pub", "add", *STORE_PACKAGES], cwd=store)
    return store


def locked_git_ref(package):
    """The resolved-ref pubspec.lock records for a git dependency."""
    lock = (REPO / "pubspec.lock").read_text(encoding="utf-8")
    block = re.search(rf"^  {re.escape(package)}:\n((?:    .*\n|      .*\n)+)", lock, re.M)
    ref = block and re.search(r'resolved-ref:\s*"?([0-9a-f]{40})"?', block.group(1))
    url = block and re.search(r'url:\s*"?([^"\n]+)"?', block.group(1))
    if not ref or not url:
        raise Failure(f"pubspec.lock has no git resolved-ref for `{package}`")
    return url.group(1), ref.group(1)


# ── Rust ─────────────────────────────────────────────────────────────────────


def rust_toolchain(tor_dir):
    """The channel of the fork's rust/rust-toolchain(.toml): the Rust whose
    standard library the library links."""
    for name in ("rust-toolchain.toml", "rust-toolchain"):
        path = tor_dir / "rust" / name
        if path.is_file():
            text = path.read_text(encoding="utf-8")
            match = re.search(r'^\s*channel\s*=\s*"([^"]+)"', text, re.M)
            return match.group(1) if match else text.strip()
    raise Failure("the tor plugin has no rust/rust-toolchain")


def check_about_config():
    config = tomllib.loads(ABOUT_TOML.read_text(encoding="utf-8"))
    if tuple(config.get("accepted", ())) != ACCEPTED:
        raise Failure("tools/licenses/about.toml `accepted` differs from generate.py's ACCEPTED")
    if sorted(config.get("targets", ())) != sorted(RUST_TARGETS):
        raise Failure("tools/licenses/about.toml `targets` differs from generate.py's RUST_TARGETS")


def cargo_about_version():
    out = run(["cargo", "about", "--version"]).strip()
    if out != f"cargo-about {CARGO_ABOUT_VERSION}":
        raise Failure(
            f"`cargo about --version` is {out!r}; install the pinned one:\n"
            f"  cargo install --locked --features cli cargo-about --version {CARGO_ABOUT_VERSION}"
        )


def cargo_about(manifest, workdir):
    out = workdir / "about.json"
    run(["cargo", "about", "generate", "--format", "json", "--frozen", "--fail",
         "-c", str(ABOUT_TOML), "--manifest-path", str(manifest), "-o", str(out)], cwd=workdir)
    return json.loads(out.read_text(encoding="utf-8"))


def crate_targets(manifest, workdir):
    """{(name, version): {targets}} for what `cargo build` compiles per target:
    normal and build edges, cargo's real feature resolution."""
    per = defaultdict(set)
    for target in RUST_TARGETS:
        out = run(["cargo", "tree", "--frozen", "--manifest-path", str(manifest), "--target", target,
                   "-e", "normal,build", "--prefix", "none", "--format", "{p}"], cwd=workdir)
        for line in out.splitlines():
            match = re.match(r"(\S+) v(\S+)", line.strip())
            if match:
                per[(match.group(1), match.group(2))].add(target)
    return per


def feature_checked_crates(curated):
    """The crates ("name version") whose reviewed files or bundled sources
    depend on a feature staying off (`absent_features`)."""
    labels = {label for label, files in curated["reviewed_files"].items()
              if any(spec.get("absent_features") for spec in files.values())}
    labels |= {f"{b['crate']} {b['version']}" for b in curated["bundled_sources"] if b.get("absent_features")}
    return sorted(labels)


def check_features_off(label, subject, absent, features):
    """`subject` (a crate's reviewed file, or its bundled sources) was
    reviewed for a build without the features `absent`: fail unless cargo
    tree reported the crate's features (`features`) and none of them is on."""
    if not absent:
        return
    key = tuple(label.split(" "))
    if key not in features:
        raise Failure(f"{label}: the review of {subject} depends on its features, which cargo tree didn't report")
    on = sorted(set(absent) & features[key])
    if on:
        raise Failure(f"{label}: the review of {subject} assumes a build without {on}, but the build enables them; review it")


def crate_features(manifest, workdir, curated):
    """{(crate, version): features enabled on any shipped target} for the
    crates whose reviewed files or bundled sources depend on a feature
    staying off."""
    features = {}
    for label in feature_checked_crates(curated):
        name, version = label.split(" ")
        on = set()
        for target in RUST_TARGETS:
            out = run(["cargo", "tree", "--frozen", "--manifest-path", str(manifest), "--target", target,
                       "-e", "features", "-i", f"{name}@{version}", "--prefix", "none"], cwd=workdir)
            on |= parse_tree_features(out, name)
        features[(name, version)] = on
    return features


def repo_key(url):
    return (url or "").strip().rstrip("/").removesuffix(".git").lower()


def vcs_commit(package):
    info = Path(package["manifest_path"]).parent / ".cargo_vcs_info.json"
    if not info.is_file():
        return None
    return json.loads(info.read_text(encoding="utf-8")).get("git", {}).get("sha1")


def pinned_span(text, spec):
    """`text` from `spec["start"]` through the end of the first `spec["end"]`
    after it, or None when either is missing."""
    start = text.find(spec["start"])
    end = text.find(spec["end"], start) if start >= 0 else -1
    return text[start:end + len(spec["end"])] if end >= 0 else None


def licence_ids(licence):
    """The licences a crate's licence entry is: its `id`, and `also` when the
    one text is several (a file reproducing more than one licence)."""
    return [licence["id"], *licence.get("also", [])]


def bundled_extra(directory, label, extra, curated, texts):
    """A further licence of a bundled C library (`extra` in its
    bundled_sources entry): a file in the crate's package pinned by SHA-256,
    or a curated text for one the package leaves out. `notice` is prepended
    when `notice_file` in the package still contains it verbatim (a copyright
    line from the sources that the licence file lacks)."""
    if "file" in extra:
        text = read_text(directory / extra["file"]) if (directory / extra["file"]).is_file() else None
        if text is None or sha256(text) != extra["sha256"]:
            raise Failure(f"{label}: {extra['file']} changed; review bundled_sources in curated.json")
        origin = f"{label}: {extra['file']}"
    else:
        text = curated_text(curated, extra["text"])
        origin = curated["texts"][extra["text"]]["url"]
    if extra.get("notice"):
        source = directory / extra["notice_file"]
        if not source.is_file() or extra["notice"] not in read_text(source):
            raise Failure(f"{label}: {extra['notice_file']} no longer has {extra['notice']!r}; review bundled_sources")
        text = extra["notice"] + "\n\n" + text
    return {"id": extra["license"], "text": texts.add(text), "origin": origin}


def source_snippet(directory, spec, label):
    """The lines from `spec["start"]` through `spec["end"]` of a file in a
    crate's package, pinned by SHA-256, without their comment markers."""
    snippet = pinned_span(read_text(directory / spec["file"]), spec)
    if snippet is None or sha256(snippet) != spec["sha256"]:
        raise Failure(f"{label}: {spec['file']} no longer has the header curated.json pins; review source_notices")
    lines = [re.sub(r"^\s*(?://+|/?\*+/?)\s?", "", line).rstrip() for line in snippet.splitlines()]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip() + "\n"


def package_files(directory, pattern, skip=()):
    """The files in a crate's package directory whose names match, sorted,
    leaving out third-party notice files and those named in `skip`."""
    if not directory.is_dir():
        return []
    return sorted(
        f for f in directory.iterdir()
        if f.is_file() and pattern.match(f.name) and not THIRD_PARTY_FILE.search(f.name) and f.name not in skip
    )


def files_to_review(directory, already_shipped=()):
    """The package's files that need a review: third-party notice files at
    its root, and licence-named files below it, outside tests, examples,
    benches and docs, and other than those shipped already (bundled
    sources' licences). Paths relative to the package."""
    if not directory.is_dir():
        return []
    found = []
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory)
        if not path.is_file() or relative.parts[0] in UNCOMPILED_DIRS or str(relative) in already_shipped:
            continue
        nested = len(relative.parts) > 1
        if (nested and NESTED_LICENCE_FILE.search(path.name)) or (not nested and THIRD_PARTY_FILE.search(path.name)):
            found.append(str(relative))
    return found


def parse_tree_features(output, crate):
    """The features of `crate` in `cargo tree -e features -i <crate>` output
    (with `--prefix none`)."""
    return set(re.findall(rf'^{re.escape(crate)} feature "([^"]+)"', output, re.M))


def reviewed_notices(directory, label, curated, features, already_shipped=()):
    """A crate's reviewed files: (paths never read as its own licence,
    [(text, path)] to ship as notices, [(path, summary)] of those not shipped
    that name holders). A file to review (see files_to_review) without an
    entry in curated.json reviewed_files fails, as does a reviewed one whose
    text changed, or one excluded for a feature (`absent_features`) the build
    turns on: `features` holds what cargo tree reports per crate."""
    reviewed = curated["reviewed_files"].get(label, {})
    for path in files_to_review(directory, already_shipped):
        if path not in reviewed:
            raise Failure(
                f"{label}: its package has {path}, a licence or another project's notice: review what it covers "
                "and record it in curated.json reviewed_files"
            )
    shipped, withheld = [], []
    for path, spec in sorted(reviewed.items()):
        file = directory / path
        text = read_text(file) if file.is_file() else None
        if text is None or sha256(text) != spec["sha256"]:
            raise Failure(f"{label}: {path} is missing or changed; review curated.json reviewed_files")
        check_features_off(label, path, spec.get("absent_features", []), features)
        if spec["ship"]:
            shipped.append((text, path))
        elif copyright_statements(text):
            withheld.append((path, spec["summary"]))
    return set(reviewed), shipped, withheld


def rust_licences(about, targets, curated, tor, rust_toolchain, features):
    """The rust_licenses.json document. `rust_toolchain` is the fork's
    rust/rust-toolchain channel, whose standard library the library links;
    `features` maps (crate, version) to the features cargo tree reports for
    the crates whose reviews depend on them."""
    texts = Texts()
    crates = {(c["package"]["name"], c["package"]["version"]): c for c in about["crates"]}
    if set(crates) != set(targets):
        only_about = sorted(set(crates) - set(targets))
        only_tree = sorted(set(targets) - set(crates))
        raise Failure(f"cargo-about and cargo tree disagree on the crates: {only_about} vs {only_tree}")
    groups = defaultdict(list)
    for group in about["licenses"]:
        for use in group["used_by"]:
            key = (use["crate"]["name"], use["crate"]["version"])
            groups[key].append(group)
    upstream = defaultdict(dict)
    for entry in curated["upstream_licence_files"]:
        upstream[repo_key(entry["repository"])][entry["commit"]] = entry
    used_upstream, used_bundled, used_reviewed = set(), set(), set()
    used_bare, used_notice_files, used_source, used_third = set(), set(), set(), set()
    used_choices = set()
    bundled = {(b["crate"], b["version"]): b for b in curated["bundled_sources"]}
    bundled_names = {b["crate"] for b in curated["bundled_sources"]}
    out_crates, out_bundled = [], []

    for key in sorted(crates):
        name, version = key
        crate, package = crates[key], crates[key]["package"]
        if FOREIGN_CRATE.match(name):
            raise Failure(f"{name} {version} is for a platform Bag doesn't ship: check about.toml `targets`")
        licences, notices, notes = [], [], []
        directory = Path(package["manifest_path"]).parent
        label = f"{name} {version}"
        bundled_file = [f for b in curated["bundled_sources"] if b["crate"] == name
                        for f in [b["file"]] + [x["file"] for x in b.get("extra", []) if "file" in x]]
        skip, third_party, withheld = reviewed_notices(directory, label, curated, features, bundled_file)
        if skip:
            used_third.add(label)

        def add_licence(lid, text, origin):
            text, dropped = strip_placeholders(text)
            if dropped:
                notes.append("A template copyright line nobody filled in was left out.")
            index = texts.add(text)
            same = [l for l in licences if l["text"] == index]
            if not same:
                licences.append({"id": lid, "text": index, "origin": origin})
            elif lid not in licence_ids(same[0]):
                # One file holding several licences (aws-lc-sys's LICENSE): the
                # text ships once, and `also` names the other licences it is.
                same[0].setdefault("also", []).append(lid)

        def add_notice(text, origin):
            index = texts.add(text)
            if not any(n["text"] == index for n in notices + licences):
                notices.append({"text": index, "origin": origin})

        for group in sorted(groups[key], key=lambda g: (g["id"], g["text"])):
            lid = group["id"]
            if lid not in ACCEPTED:
                raise Failure(f"{label}: {lid} is not an accepted licence")
            if group.get("source_path"):
                add_licence(lid, group["text"], "package")
                continue
            # cargo-about read no licence file for this licence and gave its
            # template; find the real one.
            commits = upstream.get(repo_key(package.get("repository")), {})
            commit = vcs_commit(package)
            entry = commits.get(commit)
            if commits and not entry:
                raise Failure(
                    f"{label} was published from {commit}, not {' or '.join(sorted(commits))}: fetch its repository's "
                    f"licence file at that commit into tools/licenses/texts/ and add it to "
                    f"upstream_licence_files and texts in curated.json"
                )
            if entry and entry["license"] != lid:
                raise Failure(f"{label}: curated.json gives its repository's {entry['license']} text, not {lid}")
            if entry and "text" in entry:
                add_licence(lid, curated_text(curated, entry["text"]),
                            entry.get("url", curated["texts"][entry["text"]]["url"]))
                used_upstream.add((repo_key(entry["repository"]), entry["commit"]))
                continue
            if label in curated["licence_choices"]:
                # An OR whose pick has no file in the package, while another
                # option's text is there (dunce): that option, as reviewed.
                choice = curated["licence_choices"][label]
                expression = crate["license"] or ""
                options = [o.strip() for o in re.split(r"\s+OR\s+", expression)]
                if (" AND " in expression or "(" in expression or choice["license"] not in options
                        or choice["license"] not in ACCEPTED):
                    raise Failure(f"{label}: {choice['license']} is not an accepted option of {expression!r}")
                path = directory / choice["file"]
                text = read_text(path) if path.is_file() else None
                if text is None or sha256(text) != choice["sha256"]:
                    raise Failure(f"{label}: {choice['file']} changed; review curated.json licence_choices")
                if choice["license"] not in classify(text):
                    raise Failure(f"{label}: {choice['file']} isn't the {choice['license']} text")
                add_licence(choice["license"], text, f"package file {path.name}")
                notes.append(f"Used under {choice['license']}, the option of its licence whose text the package "
                             f"ships; cargo-about picked {lid}, which has no file in it.")
                used_choices.add(label)
                continue
            files = package_files(directory, LICENCE_FILE, skip)
            matching = [f for f in files if lid in classify(read_text(f))]
            for f in matching:
                add_licence(lid, read_text(f), f"package file {f.name}")
            if matching:
                continue
            if label in curated["licence_notice_files"]:
                spec = curated["licence_notice_files"][label]
                if [f.name for f in files] != spec["files"]:
                    raise Failure(f"{label}: its package's licence files are now {[f.name for f in files]}; review them")
                for f in files:
                    add_notice(read_text(f), f"package file {f.name}")
                used_notice_files.add(label)
            elif entry and "notice" in entry:
                add_notice(curated_text(curated, entry["notice"]), curated["texts"][entry["notice"]]["url"])
                used_upstream.add((repo_key(entry["repository"]), entry["commit"]))
            elif files:
                raise Failure(
                    f"{label}: its package has {[f.name for f in files]}, but none is the {lid} text: "
                    "review this crate's licence file"
                )
            elif label in curated["no_licence_file"]:
                used_bare.add(label)
            else:
                raise Failure(
                    f"{label} ships no licence file for {lid}: review this crate's licence file (record it "
                    "in curated.json no_licence_file if the package really has none)"
                )
            authors = ", ".join(re.sub(r"\s*<[^>]*>", "", a) for a in package.get("authors") or [])
            notes.append(
                f"The package ships no {lid} text, so the standard text is given"
                + (f"; authors (Cargo.toml): {authors}" if authors else "")
                + (f"; repository: {package['repository']}" if package.get("repository") else "")
                + "."
            )
            add_licence(lid, group["text"], "standard")
        for f in package_files(directory, NOTICE_FILE, skip):
            add_notice(read_text(f), f"package file {f.name}")
        for text, file in third_party:
            kind = "reviewed" if "/" in file else "third-party notice"
            add_notice(text, f"package file {file} ({kind})")
        if label in curated["source_notices"]:
            # Copyright lines its licence files lack, from a source header.
            spec = curated["source_notices"][label]
            header = source_snippet(directory, spec, label)
            add_notice(header, f"package file {spec['file']} (header)")
            used_source.add(label)
        if licences and not has_copyright_line([texts.items[t["text"]] for t in licences + notices]):
            # The licence chosen names no holder; another licence file of the
            # package may (a dual-licensed crate's LICENSE-BSD, an Apache
            # appendix filled in).
            own_files = package_files(directory, LICENCE_FILE, skip)
            statements, sources = [], []
            for f in own_files:
                found = [st for st in copyright_statements(read_text(f)) if st not in statements]
                if found:
                    statements += found
                    sources.append(f.name)
            if statements:
                add_notice("\n".join(statements) + "\n", "copyright lines of package files " + ", ".join(sources))
            elif withheld:
                reasons = "; ".join(f"{path}: {summary}" for path, summary in withheld)
                notes.append(f"Flagged: its licence files name no holder of the crate's own code (third-party notice "
                             f"reviewed: {reasons}).")
            elif own_files:
                notes.append("Flagged: no licence file in its package names a copyright holder.")
            else:
                notes.append("Flagged: the package ships no licence file.")
        if not licences:
            raise Failure(f"{name} {version}: cargo-about found no licence")
        entry = {
            "name": name,
            "version": version,
            "expression": crate["license"],
            "license": " AND ".join(dict.fromkeys(i for l in licences for i in licence_ids(l))),
            "licenses": licences,
            "targets": sorted(targets[key]),
        }
        if notices:
            entry["notices"] = notices
        if package.get("license") is None:
            notes.append("The licence is taken from the crate's licence file (see tools/licenses/about.toml).")
        if name == TOR_CRATE and package.get("source") is None:
            entry["package"] = TOR_PACKAGE
            entry["repository"] = f"{tor['url']} at {tor['ref']}"
            notes.append("The tor plugin's own Rust crate: the core of Bag's Tor library.")
        elif package.get("repository"):
            entry["repository"] = package["repository"]
        if any("MPL-2.0" in licence_ids(l) for l in licences):
            if not (package.get("source") or "").startswith("registry+"):
                raise Failure(f"{name} {version} is MPL-2.0 but doesn't come from crates.io")
            entry["source"] = f"https://crates.io/crates/{name}/{version}"
        if notes:
            entry["notes"] = list(dict.fromkeys(notes))
        out_crates.append(entry)

        native = package.get("links") or any(
            d["kind"] == "build" and d["name"] in NATIVE_BUILD_DEPS for d in package["dependencies"]
        )
        if key in bundled:
            spec = bundled[key]
            used_bundled.add(key)
            text = read_text(directory / spec["file"])
            if "start" in spec:
                text = pinned_span(text, spec)
                if text is None:
                    raise Failure(f"{name} {version}: {spec['file']} no longer has its licence notice")
            if sha256(text) != spec["sha256"]:
                raise Failure(f"{name} {version}: {spec['file']} changed; review bundled_sources in curated.json")
            check_features_off(label, f"its bundled {spec['name']} sources", spec.get("absent_features", []), features)
            if spec.get("strip_comment"):
                text = "\n".join(re.sub(r"^\*\* ?", "", line) for line in text.splitlines()) + "\n"
            if spec.get("notice"):
                text = spec["notice"] + "\n\n" + text
            item = {
                "name": spec["name"],
                "version": spec["component_version"],
                "license": spec["license"],
                "in_crate": f"{name} {version}",
                "homepage": spec["homepage"],
                "licenses": [{"id": spec["license"], "text": texts.add(text), "origin": f"{name} {version}: {spec['file']}"}],
                "targets": sorted(targets[key]),
            }
            for extra in spec.get("extra", []):
                item["licenses"].append(bundled_extra(directory, f"{name} {version}", extra, curated, texts))
            if spec.get("expression"):
                item["expression"] = spec["expression"]
            out_bundled.append(item)
        elif name in bundled_names:
            raise Failure(f"{name} is now {version}: review its bundled sources in curated.json")
        elif native:
            if name not in curated["native_code_reviewed"]:
                raise Failure(
                    f"{name} {version} compiles or links native code: list its bundled sources in curated.json "
                    "(bundled_sources), or say why there are none (native_code_reviewed)"
                )
            used_reviewed.add(name)

    every_upstream = {(r, c) for r, commits in upstream.items() for c in commits}
    stale = (
        [f"upstream_licence_files {r} {c}" for r, c in every_upstream - used_upstream]
        + [f"no_licence_file {k}" for k in set(curated["no_licence_file"]) - used_bare]
        + [f"licence_notice_files {k}" for k in set(curated["licence_notice_files"]) - used_notice_files]
        + [f"source_notices {k}" for k in set(curated["source_notices"]) - used_source]
        + [f"reviewed_files {k}" for k in set(curated["reviewed_files"]) - used_third]
        + [f"licence_choices {k}" for k in set(curated["licence_choices"]) - used_choices]
        + [f"bundled_sources {c} {v}" for c, v in set(bundled) - used_bundled]
        + [f"native_code_reviewed {n}" for n in set(curated["native_code_reviewed"]) - used_reviewed]
    )
    if stale:
        raise Failure(f"curated.json entries no longer apply: {sorted(stale)}")
    std = curated["toolchain"]
    if std["version"] != rust_toolchain:
        raise Failure(
            f"the tor plugin's rust/rust-toolchain is {rust_toolchain}, but curated.json lists the Rust "
            f"standard library {std['version']}: review its notice and update the version"
        )
    toolchain = [{
        "name": std["name"],
        "version": std["version"],
        "expression": std["expression"],
        "license": std["license"],
        "licenses": [{"id": std["license"], "text": texts.add(curated_text(curated, std["text"])),
                      "origin": curated["texts"][std["text"]]["url"]}],
        "targets": list(RUST_TARGETS),
        "notes": [std["note"]],
    }]
    return {
        "generated_by": f"tools/licenses/generate.sh (cargo-about {CARGO_ABOUT_VERSION})",
        "tor_plugin": {"url": tor["url"], "ref": tor["ref"]},
        "targets": list(RUST_TARGETS),
        "texts": texts.items,
        "crates": out_crates,
        "bundled": sorted(out_bundled, key=lambda b: b["name"].lower()),
        "toolchain": toolchain,
    }


# ── Android: declared libraries ──────────────────────────────────────────────

# The configurations whose libraries reach the release APK. Any line naming
# one must be a plain `"group:artifact:version"`; anything else (a project, a
# BOM, a version catalog, a file tree, a closure) fails, for review.
CONFIGURATIONS = (
    "implementation", "api", "runtimeOnly", "coreLibraryDesugaring",
    "releaseImplementation", "releaseApi", "releaseRuntimeOnly",
)
CONFIGURATION_LINE = re.compile(rf"^\s*({'|'.join(CONFIGURATIONS)})\b(.*)$", re.M)
PLAIN_DECLARATION = re.compile(r"""^\s*\(?\s*(['"])([^'"]+)\1\s*\)?\s*(?://.*)?$""")
KOTLIN_PLUGIN = re.compile(
    r"apply\s+plugin:\s*['\"](?:kotlin-android|org\.jetbrains\.kotlin\.android)['\"]"
    r"|\bid\s*\(?\s*['\"](?:kotlin-android|org\.jetbrains\.kotlin\.android)['\"]"
    r"|\bkotlin\s*\(\s*['\"]android['\"]\s*\)"
)


def gradle_declarations(text, where):
    """[(configuration, group, artifact, version)] a Gradle build file
    declares, with `def`/`val`/`ext.` string variables substituted."""
    variables = dict(re.findall(r"(?:\bdef|\bval|\bext\.)\s*(\w+)\s*=\s*['\"]([^'\"$]+)['\"]", text))
    found = []
    for config, rest in CONFIGURATION_LINE.findall(text):
        plain = PLAIN_DECLARATION.match(rest)
        if not plain:
            raise Failure(f"{where}: can't read the dependency `{config}{rest.rstrip()}`; review it")
        spec = plain.group(2)
        spec = re.sub(r"\$\{?(\w+)\}?", lambda m: variables.get(m.group(1), m.group(0)), spec)
        parts = spec.split(":")
        if len(parts) < 3 or "$" in spec or not parts[2]:
            raise Failure(f"{where}: can't read the version of `{spec}`")
        found.append((config, parts[0], parts[1], parts[2]))
    return found


def kotlin_plugin_version():
    settings = (REPO / "android" / "settings.gradle.kts").read_text(encoding="utf-8")
    match = re.search(r'id\("org\.jetbrains\.kotlin\.android"\)\s+version\s+"([^"]+)"', settings)
    if not match:
        raise Failure("android/settings.gradle.kts declares no Kotlin Gradle plugin version")
    return match.group(1)


def declared_android(names, roots, packages, kotlin):
    """{(group, artifact): {"versions": set, "declared_by": set}} for the
    plugins among `names` (and the app itself when `names` has the root)."""
    declared = defaultdict(lambda: {"versions": set(), "declared_by": set()})

    def add(group, artifact, version, by):
        declared[(group, artifact)]["versions"].add(version)
        declared[(group, artifact)]["declared_by"].add(by)

    for name in sorted(names):
        android = roots[name] / "android"
        files = [android / "build.gradle", android / "build.gradle.kts"]
        if name == "bag":
            files = [REPO / "android" / "app" / "build.gradle.kts"]
            label = "Bag"
        else:
            label = f"{name} {packages[name]['version']}"
        for path in files:
            if not path.is_file():
                continue
            text = path.read_text(encoding="utf-8")
            for _config, group, artifact, version in gradle_declarations(text, label):
                add(group, artifact, version, label)
            if KOTLIN_PLUGIN.search(text):
                add("org.jetbrains.kotlin", "kotlin-stdlib", kotlin, f"{label} (Kotlin)")
    return declared


def embedding_libraries(flutter_root, flutter_version):
    """The Flutter Android embedding's own dependencies: the entries of its
    files.json that its published POM includes (those with `provides`)."""
    path = flutter_root / "engine" / "src" / "flutter" / "tools" / "androidx" / "files.json"
    entries = json.loads(path.read_text(encoding="utf-8"))
    by = f"Flutter {flutter_version} Android embedding"
    return [(*e["maven_dependency"].split(":"), by) for e in entries if e.get("provides")]


# ── Android: Maven POMs ──────────────────────────────────────────────────────


def version_key(version):
    """Maven/Gradle-style ordering: numbers numerically, a qualifier
    (alpha, beta, rc …) below the release it qualifies."""
    order = {"dev": 0, "snapshot": 0, "alpha": 1, "a": 1, "beta": 2, "b": 2, "milestone": 3, "m": 3,
             "rc": 4, "cr": 4, "final": 6, "ga": 6, "release": 6, "sp": 7}
    key = []
    for part in re.findall(r"\d+|[a-zA-Z]+", version):
        key.append((2, int(part), "") if part.isdigit() else (1, order.get(part.lower(), 5), part.lower()))
    return key + [(1.5, 0, "")]  # the end of a version sits between a qualifier and a number


def fetch_pom(group, artifact, version):
    path = f"{group.replace('.', '/')}/{artifact}/{version}/{artifact}-{version}.pom"
    cached = POM_CACHE / path
    if cached.is_file():
        return cached.read_bytes()
    errors = []
    for repo in MAVEN_REPOS:
        for attempt in range(3):
            try:
                with urllib.request.urlopen(f"{repo}/{path}", timeout=60) as response:
                    data = response.read()
                cached.parent.mkdir(parents=True, exist_ok=True)
                cached.write_bytes(data)
                return data
            except urllib.error.HTTPError as e:
                errors.append(f"{repo}: {e.code}")
                if e.code == 404:
                    break
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                errors.append(f"{repo}: {e}")
            time.sleep(2 * (attempt + 1))
    raise Failure(f"can't fetch the POM of {group}:{artifact}:{version} ({'; '.join(errors)})")


def strip_namespaces(element):
    for node in element.iter():
        if isinstance(node.tag, str) and "}" in node.tag:
            node.tag = node.tag.split("}", 1)[1]
    return element


class Poms:
    """Parsed POMs: properties, dependency management, licences and runtime
    dependencies, with parents and imported BOMs applied."""

    def __init__(self):
        self.cache = {}

    def get(self, group, artifact, version):
        key = (group, artifact, version)
        if key not in self.cache:
            self.cache[key] = self._parse(group, artifact, version)
        return self.cache[key]

    def _parse(self, group, artifact, version):
        root = strip_namespaces(ET.fromstring(fetch_pom(group, artifact, version)))
        text = lambda node, tag: (node.findtext(tag) or "").strip()
        parent = root.find("parent")
        inherited = self.get(text(parent, "groupId"), text(parent, "artifactId"), text(parent, "version")) if parent is not None else None
        props = dict(inherited["props"]) if inherited else {}
        properties = root.find("properties")
        for prop in properties if properties is not None else []:
            if isinstance(prop.tag, str):
                props[prop.tag] = (prop.text or "").strip()
        props.update({"project.version": version, "version": version, "project.groupId": group,
                      "project.artifactId": artifact})
        if parent is not None:
            props["project.parent.version"] = text(parent, "version")

        def sub(value):
            for _ in range(10):
                new = re.sub(r"\$\{([^}]+)\}", lambda m: props.get(m.group(1), m.group(0)), value)
                if new == value:
                    break
                value = new
            return value

        relocation = root.find("distributionManagement/relocation")
        if relocation is not None:
            return self.get(sub(text(relocation, "groupId")) or group,
                            sub(text(relocation, "artifactId")) or artifact,
                            sub(text(relocation, "version")) or version)
        managed = dict(inherited["managed"]) if inherited else {}
        for dep in root.findall("dependencyManagement/dependencies/dependency"):
            g, a, v = sub(text(dep, "groupId")), sub(text(dep, "artifactId")), sub(text(dep, "version"))
            if text(dep, "scope") == "import":
                managed.update(self.get(g, a, v)["managed"])
            else:
                managed[(g, a)] = v
        licences = [text(l, "name") for l in root.findall("licenses/license")]
        if not licences and inherited:
            licences = inherited["licenses"]
        deps = []
        for dep in root.findall("dependencies/dependency"):
            scope = text(dep, "scope") or "compile"
            if scope not in ("compile", "runtime") or text(dep, "optional") == "true":
                continue
            g, a = sub(text(dep, "groupId")), sub(text(dep, "artifactId"))
            v = sub(text(dep, "version")) or managed.get((g, a), "")
            exact = re.fullmatch(r"\[([^,\]]+)\]", v)
            if exact:
                v = exact.group(1)
            if not v or "$" in v or re.search(r"[\[\](),]", v):
                raise Failure(f"{group}:{artifact}:{version} depends on {g}:{a} at {v!r}, which this can't resolve")
            deps.append((g, a, v))
        return {"props": props, "managed": managed, "licenses": licences, "deps": deps,
                "coordinate": (group, artifact, version)}


def maven_closure(roots, poms):
    """{(group, artifact): (version, {required by})} for `roots`
    ({(group, artifact): versions}) and their runtime dependencies. As in
    Gradle, each library is at the highest version requested, and only the
    selected versions' own dependencies count as requests: this repeats the
    walk until the requests stop changing."""
    requested = {ga: set(vs) for ga, vs in roots.items()}
    for _ in range(50):
        found = defaultdict(set)
        parents = defaultdict(set)
        for ga, vs in roots.items():
            found[ga] |= set(vs)
        selected, stack = {}, sorted(roots)
        while stack:
            ga = stack.pop()
            if ga in selected:
                continue
            # A library first met in this walk takes the highest version
            # requested so far; the next walk sees every request.
            selected[ga] = max(requested.get(ga) or found[ga], key=version_key)
            for g, a, v in poms.get(*ga, selected[ga])["deps"]:
                found[(g, a)].add(v)
                parents[(g, a)].add(ga)
                stack.append((g, a))
        found = {ga: found[ga] for ga in selected}
        if found == requested:
            return {ga: (selected[ga], parents[ga]) for ga in sorted(selected)}
        requested = found
    raise Failure("the Android dependency graph didn't settle on versions")


def maven_licence(ga, version, poms, curated):
    names = poms.get(*ga, version)["licenses"]
    ids = sorted({curated["maven_licence_names"].get(n) for n in names} - {None})
    unknown = [n for n in names if n not in curated["maven_licence_names"]]
    coordinate = f"{ga[0]}:{ga[1]}:{version}"
    if unknown:
        raise Failure(f"{coordinate}: its POM names {unknown}; classify it in curated.json maven_licence_names")
    if len(ids) != 1:
        raise Failure(f"{coordinate}: its POM names {names or 'no licence'}; review it and record it in curated.json")
    return ids[0]


def android_libraries(direct, store, poms, curated):
    """native_licenses.json's `libraries`, `texts` and `terms`."""
    def roots_of(declared):
        return {ga: d["versions"] for ga, d in declared.items()}

    every = defaultdict(lambda: {"versions": set(), "declared_by": set()})
    for declared in (direct, store):
        for ga, d in declared.items():
            every[ga]["versions"] |= d["versions"]
            every[ga]["declared_by"] |= d["declared_by"]
    closures = {
        "all": maven_closure(roots_of(direct), poms),
        "store": maven_closure(roots_of(every), poms),
    }
    texts, terms, libraries = {}, {}, []
    used_notices, used_embedded = set(), set()
    embedded = defaultdict(list)
    for item in curated["maven_embedded"]:
        embedded[item["coordinate"]].append(item)
    for flavor, closure in closures.items():
        for ga in sorted(closure):
            if flavor == "store" and ga in closures["all"]:
                continue
            version, parents = closure[ga]
            coordinate = f"{ga[0]}:{ga[1]}"
            lid = maven_licence(ga, version, poms, curated)
            library = {"coordinate": coordinate, "version": version, "license": lid, "flavor": flavor}
            if lid.startswith("LicenseRef-"):
                if flavor != "store":
                    raise Failure(f"{coordinate} {version} is proprietary ({lid}) and would ship in the direct build")
                terms[lid] = curated["proprietary_terms"][lid]
                library["terms"] = lid
            elif lid == "Apache-2.0" and coordinate not in curated["maven_notices"]:
                texts.setdefault("Apache-2.0", curated_text(curated, "Apache-2.0"))
                library["text"] = "Apache-2.0"
            elif coordinate in curated["maven_notices"]:
                notice = curated["maven_notices"][coordinate]
                texts.setdefault(notice["text"], curated_text(curated, notice["text"]))
                library["text"] = notice["text"]
                if notice.get("source"):
                    library["source"] = notice["source"]
                used_notices.add(coordinate)
            else:
                raise Failure(f"{coordinate} {version} is {lid}: add its notice to curated.json maven_notices")
            declared_by = sorted((direct if flavor == "all" else every).get(ga, {}).get("declared_by", ()))
            if declared_by:
                library["declared_by"] = declared_by
            else:
                library["required_by"] = sorted(f"{g}:{a}" for g, a in parents)
            for item in embedded.get(coordinate, []):
                texts.setdefault(item["text"], curated_text(curated, item["text"]))
                library.setdefault("embedded", []).append(
                    {"name": item["name"], "license": item["license"], "text": item["text"]})
                used_embedded.add(coordinate)
            libraries.append(library)
    libraries.sort(key=lambda l: l["coordinate"])
    stale = (set(curated["maven_notices"]) - used_notices) | (set(embedded) - used_embedded)
    if stale:
        raise Failure(f"curated.json entries no longer apply: {sorted(stale)}")
    return libraries, texts, terms


# ── Fonts ────────────────────────────────────────────────────────────────────

FONT_ASSET = re.compile(r"""^\s*-?\s*asset:\s*["']?([^"'\s#]+)""", re.M)
FONT_FILE = re.compile(r"(?i)\.(?:ttf|otf|ttc|woff2?)$")


# Fonts Flutter adds by itself: the app's `uses-material-design: true`
# bundles the Material Icons font. (A dependency's own setting bundles
# nothing; flutter_tools reads it from the app's pubspec only.)
FLUTTER_FONT_TRIGGERS = {
    "MaterialIcons": re.compile(r"^\s*uses-material-design:\s*true\b", re.M),
}


def font_notices(root, curated, flutter_root=None, flutter_version=None, packages=None):
    """The fonts the app ships, from `curated.json` fonts and flutter_fonts.
    Every font asset pubspec.yaml declares (under `fonts:`, or as a font file
    under `assets:`), every font file under assets/, and every font Flutter
    bundles because of pubspec.yaml (the Material Icons font for
    `uses-material-design: true`, CupertinoIcons for the cupertino_icons
    package) needs an entry there (its licence and notice); otherwise
    generation fails. So does every font a runtime dependency declares under
    `flutter: fonts:` or lists under `flutter: assets:` (`packages`: {name:
    root}), which flutter_tools bundles too, keyed `<package>:<asset>`
    (CupertinoIcons comes this way, from the cupertino_icons package). A
    font's licence can restrict use (non-commercial, no embedding) in ways no
    package metadata shows. With `flutter_root`, a Flutter font's notice must
    equal the licence file the Flutter SDK ships with it."""
    pubspec = (root / "pubspec.yaml").read_text(encoding="utf-8")
    bundled = {name for name, trigger in FLUTTER_FONT_TRIGGERS.items() if trigger.search(pubspec)}
    missing = sorted(bundled - set(curated["flutter_fonts"]))
    if missing:
        why = {"MaterialIcons": "pubspec.yaml's uses-material-design: true makes Flutter bundle the Material Icons font",
               "CupertinoIcons": "the cupertino_icons package ships the CupertinoIcons font"}
        raise Failure("; ".join(why[m] for m in missing) + ": add its licence and notice to curated.json flutter_fonts")
    stale = sorted(set(curated["flutter_fonts"]) - bundled)
    if stale:
        raise Failure(f"curated.json flutter_fonts entries no longer apply: {stale}")
    fonts = []
    for name in sorted(bundled):
        spec = curated["flutter_fonts"][name]
        text = curated_text(curated, spec["text"])
        if flutter_root is not None and spec.get("flutter_file"):
            shipped = read_text(Path(flutter_root) / spec["flutter_file"])
            if shipped != text:
                raise Failure(
                    f"Flutter's {spec['flutter_file']} differs from tools/licenses/{curated['texts'][spec['text']]['file']}: "
                    "the font's licence may have changed; review it"
                )
        fonts.append({"asset": spec["asset"], "name": f"{spec['name']} (bundled by Flutter {flutter_version})",
                      "package": spec["name"], "bundled_by": f"Flutter {flutter_version}", "license": spec["license"],
                      "notice": spec["notice"], "link": spec["link"], "text": text})
    declared = declared_fonts(root, pubspec)
    for package, package_root in sorted((packages or {}).items()):
        manifest = Path(package_root) / "pubspec.yaml"
        if manifest.is_file():
            text = manifest.read_text(encoding="utf-8")
            declared |= {f"{package}:{asset}" for asset in declared_fonts(Path(package_root), text)}
    on_disk = {
        str(path.relative_to(root)) for path in (root / "assets").rglob("*")
        if path.is_file() and FONT_FILE.search(path.name)
    } if (root / "assets").is_dir() else set()
    missing = sorted((declared | on_disk) - set(curated["fonts"]))
    if missing:
        raise Failure(
            f"the app ships the font(s) {missing}: record each one's licence and notice in curated.json fonts "
            "(and check it allows a paid app)"
        )
    stale = sorted(set(curated["fonts"]) - declared - on_disk)
    if stale:
        raise Failure(f"curated.json fonts entries no longer apply: {stale}")
    return fonts + [
        {"asset": asset, "name": spec["name"], "license": spec["license"], "notice": spec.get("notice", ""),
         "link": spec.get("link", ""), "text": curated_text(curated, spec["text"])}
        for asset, spec in sorted(curated["fonts"].items())
    ]


def declared_fonts(root, pubspec):
    """The font files a pubspec declares: under `flutter: fonts:`, and under
    `flutter: assets:` (see font_assets)."""
    return set(FONT_ASSET.findall(pubspec)) | set(font_assets(root, pubspec))


def font_assets(root, pubspec):
    """Font files a pubspec lists under `flutter: assets:` (`- fonts/X.ttf`
    or the map form `- path: fonts/X.ttf`), directly or in a listed
    directory (flutter_tools bundles those too)."""
    found, assets_indent = [], None
    for line in pubspec.splitlines():
        if assets_indent is None:
            match = re.match(r"^(\s+)assets:\s*$", line)
            if match:
                assets_indent = len(match.group(1))
            continue
        # `- fonts/X.ttf`, or the map form `- path: fonts/X.ttf` (its
        # `path:` key possibly after `flavors:` or `transformers:`).
        item = re.match(r"^(\s*)-\s*(?:path:\s*)?[\"']?([^\"'\s#]+)", line)
        key = re.match(r"^\s+path:\s*[\"']?([^\"'\s#]+)", line)
        if line.strip() and (len(line) - len(line.lstrip())) <= assets_indent and not item:
            assets_indent = None
            continue
        if not item and not key:
            continue
        path = key.group(1) if key else item.group(2)
        if FONT_FILE.search(path):
            found.append(path)
        elif path.endswith("/") and (root / path).is_dir():
            found += [f"{path}{f.name}" for f in sorted((root / path).iterdir()) if f.is_file() and FONT_FILE.search(f.name)]
    return found


def fonts_toc(fonts):
    """THIRD_PARTY_NOTICES.md's contents line for the fonts."""
    if not fonts:
        listed = "none"
    else:
        listed = ", ".join(
            f"{f.get('package', f['name'])}, bundled by {f['bundled_by']}" if f.get("bundled_by") else f["name"]
            for f in fonts
        )
    return f"- [Fonts](#fonts): {listed}; Bag draws its sat symbol itself"


# ── iOS ──────────────────────────────────────────────────────────────────────


def ios_check(names, roots, packages):
    """The plugins whose iOS code was read. Fails on any pod or Swift package
    dependency other than Flutter itself."""
    checked = []
    for name in sorted(names - {"bag"}):
        root = roots[name]
        specs = sorted(root.glob("ios/*.podspec")) + sorted(root.glob("darwin/*.podspec"))
        swift = sorted(root.glob("ios/*/Package.swift")) + sorted(root.glob("darwin/*/Package.swift"))
        if not specs and not swift:
            continue
        for spec in specs:
            for platform, dep in re.findall(r"^\s*\w+\.(?:(ios|osx|tvos|watchos|visionos)\.)?dependency\s+['\"]([^'\"]+)['\"]",
                                            spec.read_text(encoding="utf-8"), re.M):
                if platform in ("", "ios") and dep != "Flutter":
                    raise Failure(f"{name}: {spec.name} depends on the pod {dep!r}; classify it in generate.py")
        for manifest in swift:
            for dep in re.findall(r"\.package\s*\(([^)]*)\)", manifest.read_text(encoding="utf-8")):
                if "FlutterFramework" not in dep:
                    raise Failure(f"{name}: {manifest.parent.name}/Package.swift depends on {dep.strip()!r}")
        checked.append(f"{name} {packages[name]['version']}")
    return checked


# ── Dart ─────────────────────────────────────────────────────────────────────


def dart_packages(names, roots, packages, flavor, flutter_version):
    out = []
    for name in sorted(names):
        package = packages[name]
        entry = {"name": name, "version": package["version"], "source": package["source"], "flavor": flavor}
        licence_file = roots[name] / "LICENSE"
        if name == "sky_engine":
            size = licence_file.stat().st_size
            entry.update(license="the Flutter engine's notices", pointer=(
                f"The Flutter engine (sky_engine) carries the notices of the engine's own third-party "
                f"components in its LICENSE file ({size // 1024} KB in Flutter {flutter_version}). The app's "
                f"licence page shows it in full; it is bin/cache/pkg/sky_engine/LICENSE in the Flutter SDK, "
                f"and https://github.com/flutter/flutter/blob/{flutter_version}/engine/src/flutter/sky/packages/sky_engine/LICENSE."
            ))
        elif not licence_file.is_file():
            if package["source"] != "sdk":
                raise Failure(f"Dart package {name} {package['version']} has no LICENSE file")
            entry.update(license="BSD-3-Clause", pointer=(
                "Part of the Flutter SDK, with no licence file of its own: the Flutter SDK's licence, "
                "given under `flutter`, covers it."
            ))
        else:
            text = read_text(licence_file)
            found = classify(text)
            if not found or not set(found) <= DART_ACCEPTED:
                raise Failure(
                    f"Dart package {name} {package['version']}: can't classify its LICENSE as accepted "
                    f"(found {found or 'nothing'}); review it"
                )
            entry.update(license=", ".join(found), text=text)
            if "MPL-2.0" in found:
                if package["source"] == "hosted":
                    entry["source_url"] = f"{PUB_DEV}/{name}/versions/{package['version']}"
                else:
                    raise Failure(f"Dart package {name} is MPL-2.0 but not from pub.dev")
        out.append(entry)
    return out


# ── THIRD_PARTY_NOTICES.md ───────────────────────────────────────────────────

PLATFORMS = {"aarch64-apple-ios": "iOS"}


def platforms_of(targets):
    names = {PLATFORMS.get(t, "Android") for t in targets}
    return " and ".join(sorted(names)) if len(names) > 1 else f"{names.pop()} only"


def anchor(heading):
    """The id GitHub gives a heading: lower case, punctuation but - and _
    dropped, spaces as hyphens."""
    return re.sub(r"[^a-z0-9 _-]", "", heading.lower()).replace(" ", "-")


def fence(text):
    if "````" in text:
        raise Failure("a licence text contains ````, which would break THIRD_PARTY_NOTICES.md")
    return f"````text\n{text.strip(chr(10)).rstrip()}\n````"


def notices_md(rust, native, dart, tor, flutter_version):
    lines = []
    add = lines.append

    def numbered_texts(prefix, texts, users):
        """Each of `texts` under its own heading (`##### D1` …), with its
        users (`users[index]`, as they are to be shown)."""
        for index, text in enumerate(texts):
            add(f"##### {prefix}{index + 1}")
            add("")
            add("Used by: " + ", ".join(users[index]))
            add("")
            add(fence(text))
            add("")

    store_dart = [d for d in dart if d["flavor"] == "store"]
    store_android = [l for l in native["libraries"] if l["flavor"] == "store"]
    add("# Third-party notices")
    add("")
    add("Bag is free software, licensed under the GNU General Public License, version 3 only "
        "(GPL-3.0-only): see [LICENSE](LICENSE). Its source code is at https://github.com/UXAVIA/bag.")
    add("")
    add("Bag is built with the third-party software below. This file lists it, says which terms each part "
        "is used under, and reproduces the licence notices. The app shows the same notices on its licence "
        "page, under Settings → About → Open-source licences.")
    add("")
    add("It is generated by `tools/licenses/generate.sh` from what this tree pins: `pubspec.lock`, the "
        f"`tor` plugin's `Cargo.lock` (UXAVIA/tor at `{tor['ref']}`), and the plugins' Gradle and CocoaPods "
        f"files, with Flutter {flutter_version}. Don't edit it by hand.")
    add("")
    add(f"- [Dart packages](#dart-packages): {len(dart)}, of which {len(store_dart)} only in the Google Play "
        "and App Store builds")
    add(f"- [Rust crates](#rust-crates): {len(rust['crates'])} crates compiled into Bag's Tor library, the "
        f"{len(rust['bundled'])} C libraries bundled in them, and the Rust standard library")
    add(f"- [Android libraries](#android-libraries): {len(native['libraries'])}, of which {len(store_android)} "
        "only in the Google Play build")
    add("- [iOS libraries](#ios-libraries): none beyond Flutter and Apple's system frameworks")
    add(fonts_toc(native["fonts"]))
    add("")

    # Dart
    add("## Dart packages")
    add("")
    add("Every package the app depends on at run time (no development-only packages), with the licence "
        "file Flutter shows for it in the app. Federated plugins bring their implementations for every "
        "platform (`*_linux`, `*_windows`, `*_web` …); they are listed although the Android and iOS builds "
        "don't use them. Packages marked *store builds only* are the ones CI adds for Google Play and the "
        "App Store (in-app purchase and the rating prompt).")
    add("")
    dart_texts = Texts()
    dart_users = defaultdict(list)
    for package in dart:
        add(f"#### `{package['name']}` {package['version']}")
        add("")
        detail = [f"Licence: {package['license']}"]
        if package["flavor"] == "store":
            detail.append("store builds only")
        if package["source"] == "git" and package["name"] == TOR_PACKAGE:
            detail.append(f"from {tor['url']} at `{tor['ref']}`")
        if "text" in package:
            index = dart_texts.add(package["text"])
            dart_users[index].append(f"`{package['name']}`")
            detail.append(f"text [D{index + 1}](#d{index + 1})")
        add(" · ".join(detail))
        if package.get("source_url"):
            add("")
            add(f"Source: {package['source_url']}")
        if package.get("pointer"):
            add("")
            add(package["pointer"])
        add("")
    add("### Dart licence texts")
    add("")
    numbered_texts("D", dart_texts.items, dart_users)

    # Rust
    add("## Rust crates")
    add("")
    add("The crates `cargo` compiles into Bag's Tor library (`librust_lib_tor`, the `tor` plugin's native "
        "half) for the four targets Bag ships: Android on arm64, armv7 and x86_64, and iOS on arm64. They "
        "come from the plugin's `Cargo.lock`, and include build-time crates and macros. Where a crate "
        "offers a choice (`A OR B`), the licence it is used under is named. For an MPL-2.0 crate, the "
        "source of its unmodified files is on crates.io, at the address given. A crate's licence text is "
        "the file in its package, or, when the package has none, its repository's at the commit it was "
        "published from; failing both, the standard text, said as such. Notices that come with a crate "
        "(NOTICE, COPYRIGHT) follow its licence.")
    add("")
    rust_users = defaultdict(list)

    def rust_text_links(item):
        """`text R1, notice R2 …` for a crate's, bundled library's or the
        standard library's texts, recording it as each text's user."""
        user = f"{item['name']} {item['version']}"
        refs = []
        for licence in item["licenses"]:
            rust_users[licence["text"]].append(user)
            refs.append(f"[R{licence['text'] + 1}](#r{licence['text'] + 1})")
        for notice in item.get("notices", []):
            rust_users[notice["text"]].append(f"{user} (notice)")
            refs.append(f"notice [R{notice['text'] + 1}](#r{notice['text'] + 1})")
        return "text " + ", ".join(refs)

    for crate in rust["crates"]:
        add(f"#### `{crate['name']}` {crate['version']}")
        add("")
        terms = crate["expression"]
        if crate["license"] != crate["expression"]:
            terms += f", used under {crate['license']}"
        add(" · ".join([terms, platforms_of(crate["targets"]), rust_text_links(crate)]))
        if crate.get("source"):
            add("")
            add(f"Source: {crate['source']}")
        for note in crate.get("notes", []):
            add("")
            add(note)
        add("")
    add("### C libraries bundled in the crates")
    add("")
    add("These crates carry another project's C sources and compile them into the library.")
    add("")
    for item in rust["bundled"]:
        links = rust_text_links(item)
        add(f"#### {item['name']} {item['version']}, bundled in `{item['in_crate'].split()[0]}`")
        add("")
        terms = item.get("expression", item["license"])
        if item.get("expression"):
            terms += f", used under {item['license']}"
        add(" · ".join([terms, platforms_of(item["targets"]), item["homepage"], links]))
        add("")
    add("### Rust standard library")
    add("")
    for item in rust["toolchain"]:
        add(f"#### {item['name']} {item['version']}")
        add("")
        add(" · ".join([f"{item['expression']}, used under {item['license']}", platforms_of(item["targets"]),
                        rust_text_links(item)]))
        for note in item["notes"]:
            add("")
            add(note)
        add("")
    add("### Rust licence texts")
    add("")
    numbered_texts("R", rust["texts"], rust_users)

    # Android
    add("## Android libraries")
    add("")
    for line in native["method"]:
        add(line)
        add("")
    for library in native["libraries"]:
        add(f"#### `{library['coordinate']}` {library['version']}")
        add("")
        detail = [library["license"]]
        if library["flavor"] == "store":
            detail.append("Google Play build only")
        if "terms" in library:
            term = native["terms"][library["terms"]]
            detail.append(f"proprietary: {term['name']}, {term['url']}")
        else:
            detail.append(f"text [{library['text']}](#{anchor(library['text'])})")
        add(" · ".join(detail))
        add("")
        if library.get("declared_by"):
            add("Declared by: " + ", ".join(library["declared_by"]))
        else:
            add("Required by: " + ", ".join(f"`{r}`" for r in library["required_by"]))
        if library.get("source"):
            add("")
            add(f"Source: {library['source']}")
        for item in library.get("embedded", []):
            add("")
            add(f"Contains {item['name']}: {item['license']} · text [{item['text']}](#{anchor(item['text'])})")
        add("")
    add("### Android licence texts")
    add("")
    for key, text in sorted(native["texts"].items()):
        add(f"##### {key}")
        add("")
        add(fence(text))
        add("")

    # iOS
    add("## iOS libraries")
    add("")
    add(native["ios"]["note"])
    add("")
    add("Checked: " + ", ".join(f"`{p}`" for p in native["ios"]["checked"]))
    add("")

    # Fonts
    add("## Fonts")
    add("")
    add("Text uses the platform's fonts, and the sat symbol is drawn by Bag's own code. The fonts below "
        "ship in the app.")
    add("")
    for font in native["fonts"]:
        add(f"#### {font['name']}")
        add("")
        add(" · ".join(part for part in (f"`{font['asset']}`", font.get("notice"), f"Licence: {font['license']}",
                                         font.get("link")) if part))
        add("")
        add(fence(font["text"]))
        add("")
    return "\n".join(lines).rstrip() + "\n"


# ── Main ─────────────────────────────────────────────────────────────────────


def write_json(path, document):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document, indent=1, ensure_ascii=False, sort_keys=False) + "\n", encoding="utf-8")


def generate(workdir):
    curated = json.loads(CURATED.read_text(encoding="utf-8"))
    check_about_config()
    cargo_about_version()
    flutter_version, flutter_root = flutter_info()

    run(["flutter", "pub", "get", "--enforce-lockfile"], cwd=REPO)
    root, packages = pub_graph(REPO)
    roots = package_roots(REPO)
    runtime = runtime_closure(root, packages)

    url, ref = locked_git_ref(TOR_PACKAGE)
    tor_dir = roots[TOR_PACKAGE]
    head = run(["git", "-C", str(tor_dir), "rev-parse", "HEAD"]).strip()
    if head != ref:
        raise Failure(f"the tor plugin checkout {tor_dir.name} is at {head}, but pubspec.lock pins {ref}")
    tor = {"url": url, "ref": ref}
    manifest = tor_dir / "rust" / "Cargo.toml"

    print(f"Rust: crates of {manifest.relative_to(tor_dir.parent)}")
    run(["cargo", "fetch", "--locked", "--manifest-path", str(manifest)], cwd=workdir)
    rust = rust_licences(cargo_about(manifest, workdir), crate_targets(manifest, workdir), curated, tor,
                         rust_toolchain(tor_dir), crate_features(manifest, workdir, curated))

    print("Store flavor: resolving " + ", ".join(STORE_PACKAGES))
    store_dir = resolve_store_flavor(workdir)
    store_root, store_packages = pub_graph(store_dir)
    store_roots = package_roots(store_dir)
    store_runtime = runtime_closure(store_root, store_packages)
    if not runtime <= store_runtime:
        raise Failure(f"the store flavor drops packages: {sorted(runtime - store_runtime)}")
    store_only = store_runtime - runtime
    pinned = dict(spec.split(":") for spec in STORE_PACKAGES)
    for name, version in pinned.items():
        if store_packages[name]["version"] != version:
            raise Failure(f"the store flavor resolved {name} {store_packages[name]['version']}, not {version}")
    if set(pinned) != store_only:
        raise Failure(f"the store flavor adds {sorted(store_only)}, but STORE_PACKAGES pins {sorted(pinned)}")

    print("Android: declared libraries and their POMs")
    kotlin = kotlin_plugin_version()
    direct = declared_android(runtime | {"bag"}, roots, packages, kotlin)
    for group, artifact, version, by in embedding_libraries(flutter_root, flutter_version):
        direct[(group, artifact)]["versions"].add(version)
        direct[(group, artifact)]["declared_by"].add(by)
    store = declared_android(store_only, store_roots, store_packages, kotlin)
    libraries, texts, terms = android_libraries(direct, store, Poms(), curated)
    ios = ios_check(runtime | store_only, {**roots, **store_roots}, {**packages, **store_packages})
    fonts = font_notices(REPO, curated, flutter_root, flutter_version,
                         {name: {**roots, **store_roots}[name] for name in runtime | store_only})
    native = {
        "generated_by": "tools/licenses/generate.sh",
        "flutter": flutter_version,
        "method": [
            "The libraries the Android build packages, besides Flutter's engine (whose notices Flutter "
            "lists itself). The app, each plugin it uses (its `android/build.gradle`) and the Flutter "
            "Android embedding declare the libraries marked *Declared by*; the Kotlin Gradle plugin adds "
            "`kotlin-stdlib` to every Kotlin module. Their own runtime dependencies, marked *Required by*, "
            "come from the libraries' Maven POMs, at the highest version requested, as Gradle picks it. "
            "That is read from the published metadata, not from a Gradle build, so it can list a little "
            "more than the APK holds.",
            "Libraries marked *Google Play build only* come with the in-app purchase and rating plugins CI "
            "adds to the Play build; the GitHub and F-Droid builds don't contain them. Some of them are "
            "proprietary Google libraries, distributed under Google's terms, which are linked rather than "
            "reproduced.",
        ],
        "texts": dict(sorted(texts.items())),
        "terms": dict(sorted(terms.items())),
        "libraries": libraries,
        "fonts": fonts,
        "ios": {
            "note": "Bag's iOS plugins (their podspecs and Swift packages) depend only on Flutter and on "
                    "Apple's system frameworks (StoreKit in the App Store build), so there are no further "
                    "iOS libraries to list. The Rust crates above are linked into the iOS app too.",
            "checked": ios,
        },
    }

    dart = dart_packages(runtime, roots, packages, "all", flutter_version)
    dart += dart_packages(store_only, store_roots, store_packages, "store", flutter_version)
    dart.sort(key=lambda d: d["name"])

    write_json(RUST_JSON, rust)
    write_json(NATIVE_JSON, native)
    NOTICES_MD.write_text(notices_md(rust, native, dart, tor, flutter_version), encoding="utf-8")
    print(f"Wrote {RUST_JSON.relative_to(REPO)} ({len(rust['crates'])} crates, {len(rust['bundled'])} bundled "
          f"C libraries), {NATIVE_JSON.relative_to(REPO)} ({len(libraries)} Android libraries) and "
          f"{NOTICES_MD.relative_to(REPO)} ({len(dart)} Dart packages).")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.parse_args(argv[1:])
    with tempfile.TemporaryDirectory(prefix="bag-licenses-") as tmp:
        try:
            generate(Path(tmp))
        except Failure as failure:
            print(f"::error::{failure}" if os.environ.get("GITHUB_ACTIONS") == "true" else f"error: {failure}",
                  file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
