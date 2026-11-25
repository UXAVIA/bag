#!/usr/bin/env python3
"""Tests for generate.py's rules, on synthetic inputs (no network, no cargo):

    python3 -I tools/licenses/test_generate.py

What generate.py produces for the real dependency graph is checked by
test/licenses/licenses_test.dart, on the committed outputs.
"""

import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate  # noqa: E402

MIT = (
    "Copyright (c) 2024 Someone\n\nPermission is hereby granted, free of charge, to any person "
    "obtaining a copy of this software ... The above copyright notice and this permission notice "
    "shall be included in all copies or substantial portions of the Software.\n"
)
MPL = "Mozilla Public License Version 2.0\n==================================\n"
CURATED = json.loads(generate.CURATED.read_text(encoding="utf-8"))


def empty_curated():
    curated = json.loads(json.dumps(CURATED))
    curated["upstream_licence_files"] = []
    curated["bundled_sources"] = []
    curated["native_code_reviewed"] = {}
    curated["maven_notices"] = {}
    curated["maven_embedded"] = []
    curated["no_licence_file"] = {}
    curated["licence_notice_files"] = {}
    curated["fonts"] = {}
    curated["flutter_fonts"] = {}
    curated["source_notices"] = {}
    curated["reviewed_files"] = {}
    curated["licence_choices"] = {}
    return curated


TEMPLATE_MIT = (
    "MIT License\n\nCopyright (c) <year> <copyright holders>\n\nPermission is hereby granted, free of "
    "charge, to any person obtaining a copy of this software ... The above copyright notice and this "
    "permission notice shall be included in all copies or substantial portions of the Software.\n"
)
APACHE_BARE = ("Apache License\nVersion 2.0, January 2004\n...\nEND OF TERMS AND CONDITIONS\n\nAPPENDIX: How to apply "
               "the Apache License to your work.\n\n   Copyright [yyyy] [name of copyright owner]\n")
# A copyright line nobody filled in, as licence templates have them.
PLACEHOLDER = re.compile(r"<\s*(year|yyyy|copyright holders?|owner|fullname|name of [^>]*)\s*>"
                         r"|\[\s*(yyyy|year|fullname|owner)\s*\]"
                         r"|\{\s*(yyyy|year|copyright holders?|owner|fullname|name|name of [^}]*)\s*\}", re.I)


def crate_dir(tmp, name, version, files=None):
    """A package directory holding `files` ({name: text}); its Cargo.toml path."""
    root = Path(tmp) / f"{name}-{version}"
    root.mkdir(parents=True, exist_ok=True)
    for file, text in (files or {}).items():
        (root / file).write_text(text)
    return str(root / "Cargo.toml")


def about(*crates):
    """A cargo-about JSON document: crates as (name, version, expression,
    [(licence id, text, has a file)], extra package fields)."""
    doc = {"crates": [], "licenses": []}
    for name, version, expression, licences, extra in crates:
        package = {"name": name, "version": version, "license": expression, "authors": ["A. Author <a@x>"],
                   "repository": f"https://github.com/x/{name}", "source": "registry+https://github.com/rust-lang/crates.io-index",
                   "dependencies": [], "links": None, "manifest_path": f"/nonexistent/{name}-{version}/Cargo.toml"}
        package.update(extra)
        doc["crates"].append({"package": package, "license": expression})
        for lid, text, has_file in licences:
            doc["licenses"].append({"id": lid, "text": text, "source_path": "/x/LICENSE" if has_file else None,
                                    "used_by": [{"crate": {"name": name, "version": version}}]})
    return doc


def targets_for(doc, targets=("aarch64-linux-android", "aarch64-apple-ios")):
    return {(c["package"]["name"], c["package"]["version"]): set(targets) for c in doc["crates"]}


TOR = {"url": "https://github.com/UXAVIA/tor.git", "ref": "a" * 40}
RUST = "1.100.0"


class RustRules(unittest.TestCase):
    def build(self, doc, curated=None, targets=None, rust=RUST, features=None):
        return generate.rust_licences(doc, targets or targets_for(doc), curated or empty_curated(), TOR, rust,
                                      features or {})

    def test_the_chosen_option_of_an_or_is_recorded(self):
        out = self.build(about(("a", "1.0.0", "MIT OR Apache-2.0", [("MIT", MIT, True)], {})))
        crate = out["crates"][0]
        self.assertEqual((crate["expression"], crate["license"]), ("MIT OR Apache-2.0", "MIT"))
        self.assertEqual(out["texts"][crate["licenses"][0]["text"]], MIT)

    def test_a_licence_outside_the_accepted_list_fails(self):
        doc = about(("gpl", "1.0.0", "GPL-3.0-only", [("GPL-3.0-only", "GNU GPL", True)], {}))
        with self.assertRaisesRegex(generate.Failure, "not an accepted licence"):
            self.build(doc)

    def test_an_mpl_crate_gets_its_crates_io_source(self):
        out = self.build(about(("q", "2.7.0", "LGPL-3.0-or-later OR MPL-2.0", [("MPL-2.0", MPL, True)], {})))
        self.assertEqual(out["crates"][0]["source"], "https://crates.io/crates/q/2.7.0")
        self.assertEqual(out["crates"][0]["license"], "MPL-2.0")

    def test_an_mpl_crate_from_elsewhere_fails(self):
        doc = about(("q", "1.0.0", "MPL-2.0", [("MPL-2.0", MPL, True)], {"source": "git+https://x/q"}))
        with self.assertRaisesRegex(generate.Failure, "doesn't come from crates.io"):
            self.build(doc)

    def test_a_crate_for_another_platform_fails(self):
        for name in ("r-efi", "windows-sys", "windows_x86_64_msvc", "wasi", "wasip2", "wasix", "wasm-bindgen", "js-sys"):
            with self.subTest(name), self.assertRaisesRegex(generate.Failure, "platform Bag doesn't ship"):
                self.build(about((name, "1.0.0", "MIT", [("MIT", MIT, True)], {})))

    def test_cargo_about_and_cargo_tree_must_agree(self):
        doc = about(("a", "1.0.0", "MIT", [("MIT", MIT, True)], {}))
        with self.assertRaisesRegex(generate.Failure, "disagree"):
            self.build(doc, targets={("b", "1.0.0"): {"aarch64-apple-ios"}})

    def test_a_licence_file_cargo_about_missed_is_used_verbatim(self):
        bsd = ("Copyright (c) 2016 Someone.\n\nRedistribution and use in source and binary forms, with or without "
               "modification, are permitted provided ... Redistributions in binary form must reproduce ... "
               "Neither the name of the copyright holder ...\n")
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "dalek", "4.1.3", {"LICENSE": bsd, "README.md": "x"})
            out = self.build(about(("dalek", "4.1.3", "BSD-3-Clause", [("BSD-3-Clause", "Copyright (c) <year> <owner>.", False)],
                                    {"manifest_path": manifest})))
        crate = out["crates"][0]
        self.assertEqual(out["texts"][crate["licenses"][0]["text"]], bsd)
        self.assertEqual(crate["licenses"][0]["origin"], "package file LICENSE")
        self.assertNotIn("notes", crate)

    def test_a_licence_file_that_is_not_the_licence_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "odd", "1.0.0", {"COPYING": "Licensed under MIT or Apache, at your option.\n"})
            doc = about(("odd", "1.0.0", "MIT", [("MIT", TEMPLATE_MIT, False)], {"manifest_path": manifest}))
            with self.assertRaisesRegex(generate.Failure, "review this crate's licence file"):
                self.build(doc)
            curated = empty_curated()
            curated["licence_notice_files"] = {"odd 1.0.0": {"files": ["COPYING"], "why": "a notice"}}
            (Path(manifest).parent / "COPYING").write_text("Copyright 2016 Someone.\nLicensed under MIT.\n")
            out = self.build(doc, curated)
        crate = out["crates"][0]
        self.assertEqual([out["texts"][n["text"]] for n in crate["notices"]], ["Copyright 2016 Someone.\nLicensed under MIT.\n"])
        self.assertNotRegex(out["texts"][crate["licenses"][0]["text"]], PLACEHOLDER)
        self.assertNotIn("No copyright line", " ".join(crate.get("notes", [])))

    def test_a_crate_without_any_licence_file_fails_unless_recorded(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "bare", "1.0.0")
            doc = about(("bare", "1.0.0", "MIT", [("MIT", TEMPLATE_MIT, False)], {"manifest_path": manifest}))
            with self.assertRaisesRegex(generate.Failure, "review this crate's licence file"):
                self.build(doc)
            curated = empty_curated()
            curated["no_licence_file"] = {"bare 1.0.0": "checked: the package has no licence file"}
            out = self.build(doc, curated)
        crate = out["crates"][0]
        text = out["texts"][crate["licenses"][0]["text"]]
        self.assertNotRegex(text, PLACEHOLDER)
        self.assertIn("Permission is hereby granted", text)
        self.assertEqual(crate["licenses"][0]["origin"], "standard")
        self.assertIn("Flagged: the package ships no licence file.", crate["notes"])
        self.assertIn("A. Author", " ".join(crate["notes"]))

    def test_a_placeholder_in_a_crates_own_file_is_dropped_and_flagged(self):
        own = "MIT License\n\nCopyright (c) [year] [fullname]\n\nPermission is hereby granted ...\n"
        out = self.build(about(("getset", "0.1.6", "MIT", [("MIT", own, True)], {})))
        crate = out["crates"][0]
        self.assertNotRegex(out["texts"][crate["licenses"][0]["text"]], PLACEHOLDER)
        self.assertIn("Flagged:", " ".join(crate["notes"]))

    def test_the_apache_appendix_is_licence_text_not_a_placeholder(self):
        apache = ("Apache License\nVersion 2.0, January 2004\n...\nEND OF TERMS AND CONDITIONS\n\nAPPENDIX: How to apply "
                  "the Apache License to your work.\n\n   Copyright [yyyy] [name of copyright owner]\n")
        out = self.build(about(("a", "1.0.0", "Apache-2.0", [("Apache-2.0", apache, True)], {})))
        self.assertEqual(out["texts"][0], apache)
        self.assertIn("Flagged:", " ".join(out["crates"][0]["notes"]))

    def test_copyright_lines_in_the_other_licence_files_ship_as_a_notice(self):
        bsd = ("Copyright (c) 2018, Daniel Wagner-Hall\nAll rights reserved.\n\nRedistribution and use in source and "
               "binary forms, with or without modification, are permitted ...\n")
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "num_enum", "0.7.6", {"LICENSE-MIT": MIT.split("\n\n", 1)[1], "LICENSE-BSD": bsd,
                                                             "LICENCE-ZLIB.md": "Copyright (c) 2019 Daniel \"Lokathor\" Gee.\n"})
            mit_only = MIT.split("\n\n", 1)[1]
            out = self.build(about(("num_enum", "0.7.6", "BSD-3-Clause OR MIT OR Apache-2.0", [("MIT", mit_only, True)],
                                    {"manifest_path": manifest})))
        crate = out["crates"][0]
        self.assertEqual(out["texts"][crate["licenses"][0]["text"]], mit_only)  # the selected text is unchanged
        notice = out["texts"][crate["notices"][0]["text"]]
        self.assertEqual(notice, "Copyright (c) 2019 Daniel \"Lokathor\" Gee.\nCopyright (c) 2018, Daniel Wagner-Hall\n")
        self.assertEqual(crate["notices"][0]["origin"], "copyright lines of package files LICENCE-ZLIB.md, LICENSE-BSD")
        self.assertNotIn("Flagged", " ".join(crate.get("notes", [])))

    def test_a_copyright_statement_spanning_lines_is_kept_whole(self):
        apache_note = ("Copyright 2011-2017 Google Inc.\n          2013 Jack Lloyd\n          2013-2014 Steven Fackler\n\n"
                       "Licensed under the Apache License, Version 2.0 ...\n")
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "openssl", "0.10.81", {"COPYING": apache_note})
            out = self.build(about(("openssl", "0.10.81", "Apache-2.0", [("Apache-2.0", APACHE_BARE, True)],
                                    {"manifest_path": manifest})))
        crate = out["crates"][0]
        self.assertEqual(out["texts"][crate["notices"][0]["text"]],
                         "Copyright 2011-2017 Google Inc.\n          2013 Jack Lloyd\n          2013-2014 Steven Fackler\n")
        self.assertNotIn("Flagged", " ".join(crate.get("notes", [])))

    def test_flags_say_which_case_it_is(self):
        with tempfile.TemporaryDirectory() as tmp:
            named = crate_dir(tmp, "a", "1.0.0", {"LICENSE-MIT": "Permission is hereby granted ...\n"})
            out = self.build(about(("a", "1.0.0", "MIT", [("MIT", "Permission is hereby granted ...\n", True)],
                                    {"manifest_path": named})))
            self.assertIn("Flagged: no licence file in its package names a copyright holder.", out["crates"][0]["notes"])
            bare = crate_dir(tmp, "b", "1.0.0")
            curated = empty_curated()
            curated["no_licence_file"] = {"b 1.0.0": "checked"}
            out = self.build(about(("b", "1.0.0", "MIT", [("MIT", TEMPLATE_MIT, False)], {"manifest_path": bare})), curated)
            self.assertIn("Flagged: the package ships no licence file.", out["crates"][0]["notes"])

    def test_third_party_files_must_be_reviewed(self):
        third = "Copyright 2014-2020 The Rust Project Developers\n\nLicensed under Apache-2.0 or MIT ...\n"
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "parking", "2.2.1", {"LICENSE-MIT": MIT, "LICENSE-THIRD-PARTY": third})
            doc = about(("parking", "2.2.1", "MIT", [("MIT", MIT, True)], {"manifest_path": manifest}))
            with self.assertRaisesRegex(generate.Failure, "LICENSE-THIRD-PARTY"):
                self.build(doc)
            curated = empty_curated()
            curated["reviewed_files"] = {"parking 2.2.1": {"LICENSE-THIRD-PARTY": {
                "sha256": generate.sha256(third), "ship": True, "why": "std-derived code"}}}
            out = self.build(doc, curated)
            crate = out["crates"][0]
            self.assertEqual([n["origin"] for n in crate["notices"]], ["package file LICENSE-THIRD-PARTY (third-party notice)"])
            curated["reviewed_files"]["parking 2.2.1"]["LICENSE-THIRD-PARTY"]["sha256"] = "0" * 64
            with self.assertRaisesRegex(generate.Failure, "LICENSE-THIRD-PARTY"):
                self.build(doc, curated)
            for name in ("THIRD_PARTY", "third-party-licenses.txt"):
                other = crate_dir(tmp, "sf", "3.7.0", {"LICENSE-MIT": MIT, name: "APSL ...\n"})
                with self.subTest(name), self.assertRaisesRegex(generate.Failure, name):
                    self.build(about(("sf", "3.7.0", "MIT", [("MIT", MIT, True)], {"manifest_path": other})))
                (Path(other).parent / name).unlink()

    def test_a_reviewed_file_that_isnt_shipped_is_not_scanned_either(self):
        # minimal-lexical's LICENSE.md carries the Go Authors' BSD notice for
        # code only its `compact` feature compiles; their line must not become
        # minimal-lexical's own.
        md = "Dual licensed ...\n\nThat code (used if the `compact` feature is enabled):\n\nCopyright (c) 2009 The Go Authors.\n"
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "minimal-lexical", "0.2.1", {"LICENSE-MIT": "Permission is hereby granted ...\n",
                                                                   "LICENSE.md": md})
            curated = empty_curated()
            curated["reviewed_files"] = {"minimal-lexical 0.2.1": {"LICENSE.md": {
                "sha256": generate.sha256(md), "ship": False, "absent_features": ["compact"],
                "summary": "its Go Authors notice covers code only the off `compact` feature compiles",
                "why": "compact feature not enabled"}}}
            doc = about(("minimal-lexical", "0.2.1", "MIT OR Apache-2.0",
                         [("MIT", "Permission is hereby granted ...\n", True)], {"manifest_path": manifest}))
            off = {("minimal-lexical", "0.2.1"): {"std"}}
            out = self.build(doc, curated, features=off)
            crate = out["crates"][0]
            self.assertNotIn("notices", crate)
            self.assertIn("Flagged: its licence files name no holder of the crate's own code (third-party notice "
                          "reviewed: LICENSE.md: its Go Authors notice covers code only the off `compact` feature "
                          "compiles).", crate["notes"])
            # The exclusion holds only while the feature stays off, on every target.
            with self.assertRaisesRegex(generate.Failure, "compact"):
                self.build(doc, curated, features={("minimal-lexical", "0.2.1"): {"std", "compact"}})
            with self.assertRaisesRegex(generate.Failure, "features"):
                self.build(doc, curated, features={})

    def test_features_are_read_from_cargo_tree(self):
        output = ('libsqlite3-sys v0.37.0\nlibsqlite3-sys feature "bundled"\nlibsqlite3-sys feature "default"\n'
                  'libsqlite3-sys feature "bundled" (*)\nrusqlite feature "bundled"\nrusqlite v0.39.0\n')
        self.assertEqual(generate.parse_tree_features(output, "libsqlite3-sys"), {"bundled", "default"})

    def test_a_licence_file_below_the_package_root_must_be_reviewed(self):
        unicode = "UNICODE, INC. LICENSE AGREEMENT\n\nCopyright (c) 1991-2022 Unicode, Inc.\n"
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "regex-syntax", "0.8.11", {"LICENSE-MIT": MIT})
            pkg = Path(manifest).parent
            (pkg / "src" / "unicode_tables").mkdir(parents=True)
            (pkg / "src" / "unicode_tables" / "LICENSE-UNICODE").write_text(unicode)
            for skipped in ("tests", "examples", "benches", "docs"):
                (pkg / skipped).mkdir()
                (pkg / skipped / "LICENSE").write_text("ignored\n")
            doc = about(("regex-syntax", "0.8.11", "MIT OR Apache-2.0", [("MIT", MIT, True)], {"manifest_path": manifest}))
            with self.assertRaisesRegex(generate.Failure, "src/unicode_tables/LICENSE-UNICODE"):
                self.build(doc)
            curated = empty_curated()
            curated["reviewed_files"] = {"regex-syntax 0.8.11": {"src/unicode_tables/LICENSE-UNICODE": {
                "sha256": generate.sha256(unicode), "ship": True, "why": "compiled Unicode tables"}}}
            out = self.build(doc, curated)
        crate = out["crates"][0]
        self.assertEqual([n["origin"] for n in crate["notices"]],
                         ["package file src/unicode_tables/LICENSE-UNICODE (reviewed)"])

    def test_a_bundled_source_licence_needs_no_second_review(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "foo-src", "1.0.0", {"LICENSE-MIT": MIT})
            pkg = Path(manifest).parent
            (pkg / "foo").mkdir()
            (pkg / "foo" / "LICENSE").write_text("Foo licence\n")
            curated = empty_curated()
            curated["bundled_sources"] = [{"crate": "foo-src", "version": "1.0.0", "name": "Foo", "component_version": "9",
                                           "license": "Apache-2.0", "file": "foo/LICENSE",
                                           "sha256": generate.sha256("Foo licence\n"), "homepage": "https://foo"}]
            out = self.build(about(("foo-src", "1.0.0", "MIT", [("MIT", MIT, True)], {"manifest_path": manifest})), curated)
        self.assertEqual(out["bundled"][0]["name"], "Foo")

    def test_a_copyright_statement_in_mid_line_counts(self):
        # hashlink's MIT text: a derived work's holder, with the year on the
        # next line.
        text = ("This work is derived in part from the `linked-hash-map` crate, Copyright (c)\n"
                "2015 The Rust Project Developers\n\nPermission is hereby granted ...\n")
        self.assertTrue(generate.has_copyright_line([text]))
        self.assertEqual(generate.copyright_statements(text), ["Copyright (c) 2015 The Rust Project Developers"])
        out = self.build(about(("hashlink", "0.11.1", "MIT OR Apache-2.0", [("MIT", text, True)], {})))
        self.assertNotIn("Flagged", " ".join(out["crates"][0].get("notes", [])))
        for false_positive in ("COPYRIGHT AND PERMISSION NOTICE\n\nNOTICE TO USER ...\n",
                               "      (c) You must retain, in the Source form of any Derivative Works\n",
                               "The above copyright notice and this permission notice shall be included\n",
                               "IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE\n2016 was a year\n",
                               "Copyright (C) 2007 Free Software Foundation, Inc. <https://fsf.org/>\n"):
            with self.subTest(false_positive[:30]):
                self.assertFalse(generate.has_copyright_line([false_positive]))
                self.assertEqual(generate.copyright_statements(false_positive), [])

    def test_a_bracketed_year_counts(self):
        # memmap2 0.9.11's LICENSE-APACHE fills in the appendix but keeps the
        # brackets: `Copyright [2015] [Dan Burkert]`.
        self.assertEqual(generate.copyright_statements("Copyright [2015] [Dan Burkert]\n"),
                         ["Copyright [2015] [Dan Burkert]"])
        self.assertEqual(generate.copyright_statements("COPYRIGHT [ 2019 ] Someone\n"), ["COPYRIGHT [ 2019 ] Someone"])
        # Opening a line, it keeps its continuation lines, as an unbracketed one does.
        self.assertEqual(generate.copyright_statements("Copyright [2011-2017] Google Inc.\n          2013 Jack Lloyd\n"),
                         ["Copyright [2011-2017] Google Inc.\n          2013 Jack Lloyd"])
        self.assertEqual(generate.copyright_statements("parts derived from foo, Copyright [2016] Bar Baz\n"),
                         ["Copyright [2016] Bar Baz"])
        self.assertEqual(generate.copyright_statements("parts derived from foo, Copyright\n[2016] Bar Baz\n"),
                         ["Copyright [2016] Bar Baz"])
        apache = APACHE_BARE.replace("[yyyy] [name of copyright owner]", "[2015] [Dan Burkert]")
        bare_mit = "Permission is hereby granted ...\n"
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "memmap2", "0.9.11", {"LICENSE-MIT": bare_mit, "LICENSE-APACHE": apache})
            out = self.build(about(("memmap2", "0.9.11", "MIT OR Apache-2.0", [("MIT", bare_mit, True)],
                                    {"manifest_path": manifest})))
        crate = out["crates"][0]
        self.assertEqual(out["texts"][crate["notices"][0]["text"]], "Copyright [2015] [Dan Burkert]\n")
        self.assertNotIn("Flagged", " ".join(crate.get("notes", [])))
        # An unfilled appendix still names nobody.
        self.assertEqual(generate.copyright_statements(APACHE_BARE), [])

    def test_a_brace_template_is_a_placeholder(self):
        for line in ("Copyright (c) {yyyy} {name}", "Copyright (C) {year} {fullname}",
                     "Copyright © { yyyy } {name of copyright owner}", "(c) {year} {copyright holders}"):
            with self.subTest(line):
                self.assertTrue(generate.placeholder_copyright(line))
                self.assertEqual(generate.copyright_statements(line + "\n"), [])
        own = "MIT License\n\nCopyright (c) {yyyy} {name}\n\nPermission is hereby granted ...\n"
        out = self.build(about(("braced", "1.0.0", "MIT", [("MIT", own, True)], {})))
        crate = out["crates"][0]
        self.assertEqual(out["texts"][crate["licenses"][0]["text"]], "MIT License\n\nPermission is hereby granted ...\n")
        self.assertIn("A template copyright line nobody filled in was left out.", crate["notes"])
        self.assertIn("Flagged:", " ".join(crate["notes"]))
        # Braces around a real name are not a template.
        self.assertEqual(generate.copyright_statements("Copyright (c) 2020 {Acme Corp}\n"), ["Copyright (c) 2020 {Acme Corp}"])

    def test_copyright_unlicense_and_patents_files_below_the_root_need_review_too(self):
        for name in ("COPYRIGHT", "copyright.pm", "COPYRIGHT.txt", "UNLICENSE", "Unlicense.md", "PATENTS", "PATENTS.txt"):
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                manifest = crate_dir(tmp, "a", "1.0.0", {"LICENSE-MIT": MIT})
                pkg = Path(manifest).parent
                (pkg / "vendor").mkdir()
                (pkg / "vendor" / name).write_text("Copyright 2020 Someone Else\n")
                doc = about(("a", "1.0.0", "MIT", [("MIT", MIT, True)], {"manifest_path": manifest}))
                with self.assertRaisesRegex(generate.Failure, f"vendor/{re.escape(name)}"):
                    self.build(doc)
        # Names that only start like one are code, not notices.
        for name in ("copyrighted.rs", "patentsearch.c", "unlicensed.h"):
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                manifest = crate_dir(tmp, "a", "1.0.0", {"LICENSE-MIT": MIT})
                (Path(manifest).parent / "src").mkdir()
                (Path(manifest).parent / "src" / name).write_text("// code\n")
                self.build(about(("a", "1.0.0", "MIT", [("MIT", MIT, True)], {"manifest_path": manifest})))

    def test_one_file_holding_several_licences_keeps_every_id(self):
        # aws-lc-sys: one LICENSE reproduces Apache-2.0, ISC and BSD-3-Clause,
        # and cargo-about read none of them from a file. The text ships once,
        # and the crate's licence still names all three.
        both = ("Apache License\nVersion 2.0, January 2004\n...\n\nISC License\nPermission to use, copy, modify, "
                "and/or distribute this software for any purpose with or without fee is hereby granted, provided "
                "that the above copyright notice and this permission notice appear in all copies.\n\nBSD 3-Clause\n"
                "Redistribution and use in source and binary forms, with or without modification, are permitted "
                "... Neither the name of the copyright holder ...\n\nCopyright Amazon.com, Inc.\n")
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "aws-lc-sys", "0.47.0", {"LICENSE": both})
            doc = about(("aws-lc-sys", "0.47.0", "ISC AND Apache-2.0 AND BSD-3-Clause",
                         [("Apache-2.0", "template", False), ("BSD-3-Clause", "template", False), ("ISC", "template", False)],
                         {"manifest_path": manifest}))
            out = self.build(doc)
        crate = out["crates"][0]
        self.assertEqual(crate["license"], "Apache-2.0 AND BSD-3-Clause AND ISC")
        self.assertEqual([(l["id"], l.get("also"), l["origin"]) for l in crate["licenses"]],
                         [("Apache-2.0", ["BSD-3-Clause", "ISC"], "package file LICENSE")])

    def test_an_or_option_whose_text_the_package_ships_can_be_chosen(self):
        # dunce: `CC0-1.0 OR MIT-0 OR Apache-2.0`. cargo-about picks
        # Apache-2.0, but the package's only licence file is CC0's text.
        cc0 = "Creative Commons Legal Code\n\nCC0 1.0 Universal\n\n...\n"
        apache = "Apache License\nVersion 2.0, January 2004\n...\n"
        expr = "CC0-1.0 OR MIT-0 OR Apache-2.0"
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "dunce", "1.0.5", {"LICENSE": cc0})
            doc = about(("dunce", "1.0.5", expr, [("Apache-2.0", apache, False)], {"manifest_path": manifest}))
            with self.assertRaisesRegex(generate.Failure, "none is the Apache-2.0 text"):
                self.build(doc)
            curated = empty_curated()
            curated["licence_choices"] = {"dunce 1.0.5": {"license": "CC0-1.0", "file": "LICENSE",
                                                          "sha256": generate.sha256(cc0), "why": "test"}}
            out = self.build(doc, curated)
            crate = out["crates"][0]
            self.assertEqual((crate["expression"], crate["license"]), (expr, "CC0-1.0"))
            self.assertEqual([(l["id"], l["origin"]) for l in crate["licenses"]], [("CC0-1.0", "package file LICENSE")])
            self.assertEqual(out["texts"][crate["licenses"][0]["text"]], cc0)
            self.assertIn("Used under CC0-1.0, the option of its licence whose text the package ships; cargo-about "
                          "picked Apache-2.0, which has no file in it.", crate["notes"])
            # The choice must be one the expression offers, accepted, and the
            # file's text, unchanged.
            for bad, message in (({"license": "MIT-0"}, "not an accepted option"),
                                 ({"license": "Zlib"}, "not an accepted option"),
                                 ({"sha256": "0" * 64}, "LICENSE changed"),
                                 ({"license": "MIT"}, "not an accepted option")):
                with self.subTest(bad):
                    wrong = json.loads(json.dumps(curated))
                    wrong["licence_choices"]["dunce 1.0.5"].update(bad)
                    with self.assertRaisesRegex(generate.Failure, message):
                        self.build(doc, wrong)
            (Path(manifest).parent / "LICENSE").write_text(apache)
            curated["licence_choices"]["dunce 1.0.5"]["sha256"] = generate.sha256(apache)
            with self.assertRaisesRegex(generate.Failure, "isn't the CC0-1.0 text"):
                self.build(doc, curated)
        # An entry for a crate that no longer needs it is stale.
        with self.assertRaisesRegex(generate.Failure, "licence_choices dunce 1.0.5"):
            self.build(about(("a", "1.0.0", "MIT", [("MIT", MIT, True)], {})), curated)

    def test_a_bundled_source_ships_its_third_party_licences_too(self):
        # AWS-LC in aws-lc-sys: aws-lc/LICENSE, plus fiat-crypto's own MIT file
        # and jitterentropy's licence, which the crate doesn't include (a
        # curated text), with a copyright line found in its sources.
        main, fiat = "AWS-LC licence\n", "MIT, the fiat-crypto authors\n"
        header = "/*\n * Copyright (C) 2021 - 2025, Joshua E. Hill <josh@keypair.us>\n */\n"
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "aws-lc-sys", "0.47.0", {"LICENSE": main})
            pkg = Path(manifest).parent
            (pkg / "aws-lc" / "third_party" / "fiat").mkdir(parents=True)
            (pkg / "aws-lc" / "LICENSE").write_text(main)
            (pkg / "aws-lc" / "third_party" / "fiat" / "LICENSE").write_text(fiat)
            (pkg / "aws-lc" / "third_party" / "jent.c").write_text(header)
            curated = empty_curated()
            curated["texts"]["jent"] = CURATED["texts"]["jitterentropy-LICENSE"]
            curated["bundled_sources"] = [{
                "crate": "aws-lc-sys", "version": "0.47.0", "name": "AWS-LC", "component_version": "0.47.0",
                "license": "Apache-2.0 AND ISC", "file": "aws-lc/LICENSE", "sha256": generate.sha256(main),
                "homepage": "https://github.com/aws/aws-lc",
                "extra": [
                    {"file": "aws-lc/third_party/fiat/LICENSE", "sha256": generate.sha256(fiat), "license": "MIT",
                     "why": "compiled"},
                    {"text": "jent", "license": "BSD-3-Clause", "why": "compiled",
                     "notice": "Copyright (C) 2021 - 2025, Joshua E. Hill <josh@keypair.us>",
                     "notice_file": "aws-lc/third_party/jent.c"},
                ]}]
            doc = about(("aws-lc-sys", "0.47.0", "ISC", [("ISC", main, True)], {"manifest_path": manifest}))
            out = self.build(doc, curated)
            item = out["bundled"][0]
            self.assertEqual([(l["id"], l["origin"]) for l in item["licenses"]], [
                ("Apache-2.0 AND ISC", "aws-lc-sys 0.47.0: aws-lc/LICENSE"),
                ("MIT", "aws-lc-sys 0.47.0: aws-lc/third_party/fiat/LICENSE"),
                ("BSD-3-Clause", CURATED["texts"]["jitterentropy-LICENSE"]["url"]),
            ])
            self.assertEqual(out["texts"][item["licenses"][1]["text"]], fiat)
            jent = out["texts"][item["licenses"][2]["text"]]
            self.assertTrue(jent.startswith("Copyright (C) 2021 - 2025, Joshua E. Hill <josh@keypair.us>\n\n"))
            self.assertIn("Stephan Mueller", jent)
            # The extra files are shipped, so they need no second review.
            self.assertNotIn("notices", out["crates"][0])
            # A changed extra file, or a notice its source no longer has, fails.
            (pkg / "aws-lc" / "third_party" / "fiat" / "LICENSE").write_text(fiat + "changed\n")
            with self.assertRaisesRegex(generate.Failure, "fiat/LICENSE changed"):
                self.build(doc, curated)
            (pkg / "aws-lc" / "third_party" / "fiat" / "LICENSE").write_text(fiat)
            (pkg / "aws-lc" / "third_party" / "jent.c").write_text("/* no copyright line */\n")
            with self.assertRaisesRegex(generate.Failure, "jent.c no longer has"):
                self.build(doc, curated)

    def test_a_bundled_source_can_depend_on_features_staying_off(self):
        # zstd-sys compiles zstd/lib/dictBuilder (divsufsort.c: MIT, Yuta
        # Mori) only with `zdict_builder`, and zstd/lib/legacy (BSD-2-Clause
        # blocks) only with `legacy`; both are default features.
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "zstd-sys", "2.0.16+zstd.1.5.7", {"LICENSE-MIT": MIT})
            pkg = Path(manifest).parent
            (pkg / "zstd").mkdir()
            (pkg / "zstd" / "LICENSE").write_text("BSD licence\n")
            curated = empty_curated()
            curated["bundled_sources"] = [{"crate": "zstd-sys", "version": "2.0.16+zstd.1.5.7", "name": "Zstandard",
                                           "component_version": "1.5.7", "license": "BSD-3-Clause",
                                           "file": "zstd/LICENSE", "sha256": generate.sha256("BSD licence\n"),
                                           "homepage": "https://facebook.github.io/zstd/",
                                           "absent_features": ["zdict_builder", "legacy"]}]
            doc = about(("zstd-sys", "2.0.16+zstd.1.5.7", "MIT OR Apache-2.0", [("MIT", MIT, True)],
                         {"manifest_path": manifest}))
            key = ("zstd-sys", "2.0.16+zstd.1.5.7")
            out = self.build(doc, curated, features={key: {"std"}})
            self.assertEqual(out["bundled"][0]["name"], "Zstandard")
            for on in ("zdict_builder", "legacy"):
                with self.subTest(on), self.assertRaisesRegex(generate.Failure, f"zstd-sys.*{on}"):
                    self.build(doc, curated, features={key: {"std", on}})
            with self.assertRaisesRegex(generate.Failure, "cargo tree didn't report"):
                self.build(doc, curated, features={})
        self.assertIn("zstd-sys 2.0.16+zstd.1.5.7", generate.feature_checked_crates(curated))

    def test_notice_and_copyright_files_ship_with_the_crate(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "rand", "0.8.6", {"COPYRIGHT": "Copyrights in the Rand project are retained by their contributors.\n",
                                                         "NOTICE": "Rand\nCopyright 2018 Developers of the Rand project\n"})
            out = self.build(about(("rand", "0.8.6", "MIT OR Apache-2.0", [("MIT", MIT, True)], {"manifest_path": manifest})))
        crate = out["crates"][0]
        self.assertEqual([n["origin"] for n in crate["notices"]], ["package file COPYRIGHT", "package file NOTICE"])

    def test_the_rust_standard_library_is_listed_at_the_forks_toolchain(self):
        out = self.build(about(("a", "1.0.0", "MIT", [("MIT", MIT, True)], {})))
        std = out["toolchain"][0]
        self.assertEqual((std["name"], std["version"], std["license"]), ("Rust standard library", RUST, "MIT"))
        self.assertIn("The Rust Project Contributors", out["texts"][std["licenses"][0]["text"]])
        with self.assertRaisesRegex(generate.Failure, "rust-toolchain"):
            self.build(about(("a", "1.0.0", "MIT", [("MIT", MIT, True)], {})), rust="1.92.0")

    def test_an_upstream_licence_file_must_match_the_publishing_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            crate_dir = Path(tmp) / "tor-x-1.0.0"
            crate_dir.mkdir()
            (crate_dir / ".cargo_vcs_info.json").write_text(json.dumps({"git": {"sha1": "b" * 40}}))
            curated = empty_curated()
            curated["upstream_licence_files"] = [{"repository": "https://gitlab.example/arti.git/",
                                                   "commit": "c" * 40, "license": "MIT", "text": "arti-MIT"}]
            doc = about(("tor-x", "1.0.0", "MIT", [("MIT", "standard", False)],
                         {"repository": "https://gitlab.example/arti.git",
                          "manifest_path": str(crate_dir / "Cargo.toml")}))
            with self.assertRaisesRegex(generate.Failure, "was published from b+, not c+"):
                self.build(doc, curated)
            curated["upstream_licence_files"][0]["commit"] = "b" * 40
            out = self.build(doc, curated)
            self.assertIn("The Tor Project", out["texts"][out["crates"][0]["licenses"][0]["text"]])

    def test_native_code_must_be_reviewed(self):
        doc = about(("libfoo-sys", "1.0.0", "MIT", [("MIT", MIT, True)], {"links": "foo"}))
        with self.assertRaisesRegex(generate.Failure, "compiles or links native code"):
            self.build(doc)
        doc = about(("cfoo", "1.0.0", "MIT", [("MIT", MIT, True)],
                     {"dependencies": [{"name": "cc", "kind": "build"}]}))
        with self.assertRaisesRegex(generate.Failure, "compiles or links native code"):
            self.build(doc)
        curated = empty_curated()
        curated["native_code_reviewed"] = {"cfoo": "its own C"}
        self.build(doc, curated)

    def test_a_bundled_source_is_pinned_to_its_crate_version_and_checksum(self):
        with tempfile.TemporaryDirectory() as tmp:
            crate_dir = Path(tmp) / "foo-src-1.0.0"
            (crate_dir / "foo").mkdir(parents=True)
            (crate_dir / "foo" / "LICENSE").write_text("Foo licence\n")
            spec = {"crate": "foo-src", "version": "1.0.0", "name": "Foo", "component_version": "9",
                    "license": "Apache-2.0", "file": "foo/LICENSE", "sha256": generate.sha256("Foo licence\n"),
                    "homepage": "https://foo"}
            curated = empty_curated()
            curated["bundled_sources"] = [spec]
            doc = about(("foo-src", "1.0.0", "MIT", [("MIT", MIT, True)],
                         {"manifest_path": str(crate_dir / "Cargo.toml")}))
            out = self.build(doc, curated)
            self.assertEqual(out["bundled"][0]["in_crate"], "foo-src 1.0.0")
            (crate_dir / "foo" / "LICENSE").write_text("Foo licence, changed\n")
            with self.assertRaisesRegex(generate.Failure, "changed; review bundled_sources"):
                self.build(doc, curated)
            doc["crates"][0]["package"]["version"] = "1.0.1"
            doc["licenses"][0]["used_by"][0]["crate"]["version"] = "1.0.1"
            with self.assertRaisesRegex(generate.Failure, "is now 1.0.1"):
                self.build(doc, curated)

    def test_curated_entries_that_no_longer_apply_fail(self):
        curated = empty_curated()
        curated["native_code_reviewed"] = {"gone": "was here"}
        with self.assertRaisesRegex(generate.Failure, "no longer apply"):
            self.build(about(("a", "1.0.0", "MIT", [("MIT", MIT, True)], {})), curated)

    def test_the_plugin_crate_is_listed_as_the_tor_package(self):
        doc = about(("rust_lib_tor", "0.2.1", "MIT", [("MIT", MIT, True)], {"source": None, "license": None}))
        crate = self.build(doc)["crates"][0]
        self.assertEqual(crate["package"], "tor")
        self.assertIn(TOR["ref"], crate["repository"])


class Classification(unittest.TestCase):
    def test_licence_texts(self):
        cases = {
            MIT: ["MIT"],
            MPL + "... GNU General Public License, Version 2.0, the GNU Lesser General Public License ...": ["MPL-2.0"],
            "Redistribution and use in source and binary forms, with or without modification, are permitted "
            "provided ... Redistributions in binary form must reproduce ... Neither the name of X": ["BSD-3-Clause"],
            "Redistribution and use in source and binary forms, with or without modification, are permitted "
            "provided ... Redistributions in binary form must reproduce the above": ["BSD-2-Clause"],
            "GNU GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007": ["GPL"],
            "This program is free software: you can redistribute it and/or modify it under the terms of the GNU "
            "General Public License": ["GPL"],
            "                                 Apache License\n                           Version 2.0, January 2004": ["Apache-2.0"],
            "Something else entirely": [],
        }
        for text, expected in cases.items():
            with self.subTest(text[:40]):
                self.assertEqual(generate.classify(text), expected)

    def test_an_unclassifiable_or_gpl_dart_licence_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "LICENSE").write_text("All rights reserved.\n")
            packages = {"p": {"version": "1.0.0", "source": "hosted"}}
            with self.assertRaisesRegex(generate.Failure, "can't classify"):
                generate.dart_packages({"p"}, {"p": root}, packages, "all", "3.41.6")
            (root / "LICENSE").write_text("GNU GENERAL PUBLIC LICENSE\nVersion 2, June 1991\n")
            with self.assertRaisesRegex(generate.Failure, "can't classify"):
                generate.dart_packages({"p"}, {"p": root}, packages, "all", "3.41.6")
            (root / "LICENSE").write_text(MPL)
            out = generate.dart_packages({"p"}, {"p": root}, packages, "all", "3.41.6")
            self.assertEqual(out[0]["source_url"], "https://pub.dev/packages/p/versions/1.0.0")


class GradleAndPods(unittest.TestCase):
    def test_declarations_skip_tests_and_the_buildscript(self):
        text = """
buildscript {
    ext.kotlin_version = '1.9.0'
    dependencies { classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlin_version" }
}
dependencies {
    def work_version = "2.9.0"
    implementation "androidx.work:work-runtime:$work_version"
    api("androidx.core:core:1.13.1")
    implementation "org.jetbrains.kotlin:kotlin-stdlib-jdk8:${kotlin_version}"
    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'
    testImplementation 'junit:junit:4.13.2'
    androidTestImplementation("androidx.test:runner:1.7.0")
    compileOnly 'x:y:1'
}
"""
        self.assertEqual(
            [d[1:] for d in generate.gradle_declarations(text, "p")],
            [("androidx.work", "work-runtime", "2.9.0"), ("androidx.core", "core", "1.13.1"),
             ("org.jetbrains.kotlin", "kotlin-stdlib-jdk8", "1.9.0"),
             ("com.android.tools", "desugar_jdk_libs", "2.1.4")],
        )

    def test_an_unreadable_version_fails(self):
        with self.assertRaisesRegex(generate.Failure, "can't read the version"):
            generate.gradle_declarations('implementation "a:b:$unknown"', "p")
        with self.assertRaisesRegex(generate.Failure, "can't read the version"):
            generate.gradle_declarations('implementation "a:b"', "p")

    def test_any_dependency_line_it_cant_read_fails(self):
        for line in ("implementation project(':core')", "implementation(libs.androidx.core)",
                     'implementation platform("com.google.firebase:firebase-bom:33.0.0")',
                     "api fileTree(dir: 'libs', include: ['*.jar'])",
                     "implementation('a:b:1.0') { exclude group: 'x' }",
                     'releaseImplementation "a:b:1.0" + suffix'):
            with self.subTest(line), self.assertRaisesRegex(generate.Failure, "can't read"):
                generate.gradle_declarations(f"dependencies {{\n    {line}\n}}\n", "p")
        self.assertEqual(generate.gradle_declarations('    releaseImplementation("a:b:1.0") // ships\n', "p"),
                         [("releaseImplementation", "a", "b", "1.0")])

    def test_an_ios_dependency_other_than_flutter_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ios").mkdir()
            spec = root / "ios" / "p.podspec"
            spec.write_text("s.dependency 'Flutter'\ns.osx.dependency 'FlutterMacOS'\n")
            packages = {"p": {"version": "1.0.0"}}
            self.assertEqual(generate.ios_check({"p"}, {"p": root}, packages), ["p 1.0.0"])
            spec.write_text("s.dependency 'Flutter'\ns.ios.dependency 'GoogleMLKit'\n")
            with self.assertRaisesRegex(generate.Failure, "GoogleMLKit"):
                generate.ios_check({"p"}, {"p": root}, packages)


class Fonts(unittest.TestCase):
    def test_a_font_needs_a_curated_notice(self):
        pubspec = ("flutter:\n  assets:\n    - assets/images/\n  fonts:\n    - family: Sat\n      fonts:\n"
                   "        - asset: assets/fonts/sat.ttf\n")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pubspec.yaml").write_text(pubspec)
            with self.assertRaisesRegex(generate.Failure, "assets/fonts/sat.ttf"):
                generate.font_notices(root, empty_curated())
            curated = empty_curated()
            curated["fonts"] = {"assets/fonts/sat.ttf": {"name": "Sat", "license": "OFL-1.1", "text": "Apache-2.0",
                                                         "why": "test"}}
            fonts = generate.font_notices(root, curated)
            self.assertEqual([f["asset"] for f in fonts], ["assets/fonts/sat.ttf"])
            (root / "pubspec.yaml").write_text("flutter:\n  assets:\n    - assets/fonts/\n")
            (root / "assets" / "fonts").mkdir(parents=True)
            (root / "assets" / "fonts" / "other.otf").write_bytes(b"\0")
            with self.assertRaisesRegex(generate.Failure, "assets/fonts/other.otf"):
                generate.font_notices(root, empty_curated())

    def flutter_root(self, tmp, licence="Attribution 4.0 International\n"):
        root = Path(tmp) / "flutter"
        (root / "bin/cache/artifacts/material_fonts").mkdir(parents=True)
        (root / "bin/cache/artifacts/material_fonts/MaterialIcons_LICENSE.txt").write_text(licence)
        return root

    def material_curated(self, licence_key="material-icons"):
        curated = empty_curated()
        curated["flutter_fonts"] = {"MaterialIcons": json.loads(json.dumps(CURATED["flutter_fonts"]["MaterialIcons"]))}
        curated["flutter_fonts"]["MaterialIcons"]["text"] = licence_key
        return curated

    def test_material_design_needs_the_material_icons_notice(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pubspec.yaml").write_text("flutter:\n  uses-material-design: true\n")
            real = generate.curated_text(CURATED, "material-icons")
            flutter = self.flutter_root(tmp, real)
            with self.assertRaisesRegex(generate.Failure, "uses-material-design"):
                generate.font_notices(root, empty_curated(), flutter, "3.41.6")
            fonts = generate.font_notices(root, self.material_curated(), flutter, "3.41.6")
            self.assertEqual([f["name"] for f in fonts], ["Material Icons font (bundled by Flutter 3.41.6)"])
            self.assertEqual(fonts[0]["license"], "CC-BY-4.0")
            self.assertIn("Google", fonts[0]["notice"])
            self.assertIn("Attribution 4.0 International", fonts[0]["text"])
            self.assertEqual(fonts[0]["link"], "https://github.com/google/material-design-icons")

    def test_the_notice_must_match_the_licence_flutter_ships(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pubspec.yaml").write_text("flutter:\n  uses-material-design: true\n")
            flutter = self.flutter_root(tmp, "Some other licence\n")
            with self.assertRaisesRegex(generate.Failure, "MaterialIcons_LICENSE.txt"):
                generate.font_notices(root, self.material_curated(), flutter, "3.41.6")

    def test_without_material_design_the_entry_is_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pubspec.yaml").write_text("flutter:\n  uses-material-design: false\n")
            self.assertEqual(generate.font_notices(root, empty_curated()), [])
            with self.assertRaisesRegex(generate.Failure, "no longer apply"):
                generate.font_notices(root, self.material_curated(), self.flutter_root(tmp), "3.41.6")

    def test_a_font_a_dependency_bundles_needs_its_notice(self):
        # flutter_tools bundles `flutter: fonts:` from every runtime
        # dependency (CupertinoIcons, for instance), transitive ones included.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "app"
            root.mkdir()
            (root / "pubspec.yaml").write_text("flutter:\n  uses-material-design: false\n")
            dep = Path(tmp) / "deep_dep"
            dep.mkdir()
            (dep / "pubspec.yaml").write_text("name: deep_dep\nflutter:\n  fonts:\n    - family: CupertinoIcons\n"
                                              "      fonts:\n        - asset: assets/CupertinoIcons.ttf\n")
            plain = Path(tmp) / "plain"
            plain.mkdir()
            (plain / "pubspec.yaml").write_text("name: plain\nflutter:\n  uses-material-design: true\n")
            deps = {"deep_dep": dep, "plain": plain}
            with self.assertRaisesRegex(generate.Failure, "deep_dep:assets/CupertinoIcons.ttf"):
                generate.font_notices(root, empty_curated(), packages=deps)
            curated = empty_curated()
            curated["fonts"] = {"deep_dep:assets/CupertinoIcons.ttf": {"name": "CupertinoIcons", "license": "MIT",
                                                                       "text": "Apache-2.0", "why": "test"}}
            fonts = generate.font_notices(root, curated, packages=deps)
            # A dependency's own uses-material-design bundles nothing (only the app's does).
            self.assertEqual([f["asset"] for f in fonts], ["deep_dep:assets/CupertinoIcons.ttf"])

    def test_a_font_file_a_dependency_lists_as_an_asset_needs_its_notice(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "app"
            root.mkdir()
            (root / "pubspec.yaml").write_text("flutter:\n  uses-material-design: false\n")
            dep = Path(tmp) / "icons_dep"
            (dep / "assets" / "fonts").mkdir(parents=True)
            (dep / "assets" / "fonts" / "Icons.otf").write_bytes(b"\0")
            (dep / "assets" / "fonts" / "readme.txt").write_text("x")
            (dep / "pubspec.yaml").write_text("name: icons_dep\nflutter:\n  assets:\n    - images/logo.png\n"
                                              "    - fonts/Extra.ttf\n    - assets/fonts/\n")
            with self.assertRaisesRegex(generate.Failure, r"icons_dep:assets/fonts/Icons.otf.*icons_dep:fonts/Extra.ttf"):
                generate.font_notices(root, empty_curated(), packages={"icons_dep": dep})

    def test_the_map_form_of_an_asset_counts_too(self):
        # `- path: …` (with `flavors:` or `transformers:` under it) lists an
        # asset just as a plain `- …` does.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "app"
            root.mkdir()
            (root / "pubspec.yaml").write_text("flutter:\n  uses-material-design: false\n  assets:\n"
                                               "    - path: fonts/App.ttf\n      flavors:\n        - store\n")
            dep = Path(tmp) / "map_dep"
            (dep / "glyphs").mkdir(parents=True)
            (dep / "glyphs" / "Glyphs.woff2").write_bytes(b"\0")
            (dep / "pubspec.yaml").write_text("name: map_dep\nflutter:\n  assets:\n    - path: \"fonts/Map.ttf\"\n"
                                              "      flavors:\n        - direct\n    - path: glyphs/\n"
                                              "    - path: images/logo.svg\n      transformers:\n"
                                              "        - package: vector_graphics_compiler\n"
                                              "    - flavors:\n        - store\n      path: fonts/Late.otf\n")
            with self.assertRaisesRegex(generate.Failure, r"fonts/App.ttf.*map_dep:fonts/Late.otf.*map_dep:fonts/Map.ttf"
                                                          r".*map_dep:glyphs/Glyphs.woff2"):
                generate.font_notices(root, empty_curated(), packages={"map_dep": dep})

    def test_the_fonts_contents_line_reads_well(self):
        self.assertEqual(generate.fonts_toc([]), "- [Fonts](#fonts): none; Bag draws its sat symbol itself")
        self.assertEqual(
            generate.fonts_toc([{"package": "Material Icons font", "name": "Material Icons font (bundled by Flutter 3.41.6)",
                                 "bundled_by": "Flutter 3.41.6"}]),
            "- [Fonts](#fonts): Material Icons font, bundled by Flutter 3.41.6; Bag draws its sat symbol itself",
        )

    def test_the_app_ships_only_the_material_icons_font(self):
        fonts = generate.font_notices(generate.REPO, CURATED, None, "3.41.6")
        self.assertEqual([f["asset"] for f in fonts], ["fonts/MaterialIcons-Regular.otf"])


class Pins(unittest.TestCase):
    def test_the_rust_notices_are_for_the_tor_ref_pubspec_lock_pins(self):
        lock = (generate.REPO / "pubspec.lock").read_text(encoding="utf-8")
        if not re.search(r"^  tor:\n", lock, re.M):
            self.skipTest("pubspec.lock has no `tor` package (a worktree on the Tor stub): nothing to compare")
        _, ref = generate.locked_git_ref("tor")
        rust = json.loads(generate.RUST_JSON.read_text(encoding="utf-8"))
        self.assertEqual(rust["tor_plugin"]["ref"], ref,
                         "the tor pin moved: run bash tools/licenses/generate.sh and commit its output")

    def test_zstd_is_checked_without_the_dictionary_builder_and_legacy_formats(self):
        # divsufsort.c (MIT, Yuta Mori, in its header only) and the legacy
        # decoders' BSD-2-Clause blocks are compiled only with these features.
        zstd = [b for b in CURATED["bundled_sources"] if b["crate"] == "zstd-sys"]
        self.assertEqual(len(zstd), 1)
        self.assertEqual(set(zstd[0].get("absent_features", [])), {"zdict_builder", "legacy"})
        self.assertIn(f"zstd-sys {zstd[0]['version']}", generate.feature_checked_crates(CURATED))

    def test_curated_reasons_name_no_fork_commit(self):
        # A reason tied to a fork commit would go stale silently when the pin
        # moves; what depends on the fork is checked by generation instead.
        text = generate.CURATED.read_text(encoding="utf-8")
        self.assertIsNone(re.search(r"(?i)\bfork\b[^\"]{0,40}\b[0-9a-f]{7,40}\b", text))


class SourceNotices(unittest.TestCase):
    def test_copyright_lines_from_a_source_header_ship_as_a_notice(self):
        header = ("// SPDX-License-Identifier: Apache-2.0\n//\n// Written in 2020 by A. Author\n//\n"
                  "// Copyright (C) 2020 A. Author.\n// All rights reserved.\n//\n// Licensed under ...\n")
        with tempfile.TemporaryDirectory() as tmp:
            manifest = crate_dir(tmp, "num", "0.5.4", {"LICENSE": APACHE_BARE})
            (Path(manifest).parent / "src").mkdir()
            (Path(manifest).parent / "src" / "lib.rs").write_text(header)
            doc = about(("num", "0.5.4", "Apache-2.0", [("Apache-2.0", APACHE_BARE, True)], {"manifest_path": manifest}))
            curated = empty_curated()
            snippet = "// Written in 2020 by A. Author\n//\n// Copyright (C) 2020 A. Author.\n// All rights reserved."
            curated["source_notices"] = {"num 0.5.4": {"file": "src/lib.rs", "start": "// Written in", "end": "// All rights reserved.",
                                                       "sha256": generate.sha256(snippet), "why": "test"}}
            out = generate.rust_licences(doc, targets_for(doc), curated, TOR, RUST, {})
            crate = out["crates"][0]
            self.assertEqual(out["texts"][crate["notices"][0]["text"]],
                             "Written in 2020 by A. Author\n\nCopyright (C) 2020 A. Author.\nAll rights reserved.\n")
            self.assertEqual(crate["notices"][0]["origin"], "package file src/lib.rs (header)")
            self.assertNotIn("Flagged", " ".join(crate.get("notes", [])))
            (Path(manifest).parent / "src" / "lib.rs").write_text(header.replace("2020 A.", "2021 A."))
            with self.assertRaisesRegex(generate.Failure, "src/lib.rs"):
                generate.rust_licences(doc, targets_for(doc), curated, TOR, RUST, {})


class StoreFlavor(unittest.TestCase):
    def test_every_store_package_is_pinned_exactly(self):
        for spec in generate.STORE_PACKAGES:
            self.assertRegex(spec, r"^[a-z_]+:\d+\.\d+\.\d+$")
        names = {spec.split(":")[0] for spec in generate.STORE_PACKAGES}
        self.assertEqual(names, {"in_app_purchase", "in_app_purchase_android", "in_app_purchase_platform_interface",
                                 "in_app_purchase_storekit", "in_app_review", "in_app_review_platform_interface"})


class Maven(unittest.TestCase):
    """The POM walk, against POMs written to a scratch cache."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = generate.POM_CACHE
        generate.POM_CACHE = Path(self.tmp.name)

    def tearDown(self):
        generate.POM_CACHE = self.saved
        self.tmp.cleanup()

    def pom(self, g, a, v, deps=(), licence="The Apache Software License, Version 2.0", extra=""):
        path = generate.POM_CACHE / f"{g.replace('.', '/')}/{a}/{v}/{a}-{v}.pom"
        path.parent.mkdir(parents=True, exist_ok=True)
        dependencies = "".join(
            f"<dependency><groupId>{dg}</groupId><artifactId>{da}</artifactId><version>{dv}</version>{scope}</dependency>"
            for dg, da, dv, *rest in deps for scope in [f"<scope>{rest[0]}</scope>" if rest else ""]
        )
        licences = f"<licenses><license><name>{licence}</name></license></licenses>" if licence else ""
        path.write_text(
            f'<project xmlns="http://maven.apache.org/POM/4.0.0"><groupId>{g}</groupId><artifactId>{a}</artifactId>'
            f"<version>{v}</version>{licences}{extra}<dependencies>{dependencies}</dependencies></project>"
        )

    def test_versions_order_like_gradle(self):
        ordered = ["1.0-alpha01", "1.0-beta02", "1.0-rc01", "1.0", "1.0.1", "1.9.1", "1.10.0", "2"]
        self.assertEqual(sorted(reversed(ordered), key=generate.version_key), ordered)

    def test_the_highest_version_wins_and_an_evicted_version_brings_nothing(self):
        self.pom("g", "app", "1", [("g", "lib", "1.0"), ("g", "other", "1")])
        self.pom("g", "other", "1", [("g", "lib", "2.0")])
        self.pom("g", "lib", "1.0", [("g", "old-only", "1")])
        self.pom("g", "lib", "2.0", [("g", "test-only", "1", "test")])
        self.pom("g", "old-only", "1")
        closure = generate.maven_closure({("g", "app"): {"1"}}, generate.Poms())
        self.assertEqual(closure[("g", "lib")][0], "2.0")
        self.assertNotIn(("g", "old-only"), closure)
        self.assertNotIn(("g", "test-only"), closure)
        self.assertEqual(closure[("g", "lib")][1], {("g", "app"), ("g", "other")})

    def test_a_pom_without_a_namespace_and_a_parent_licence(self):
        path = generate.POM_CACHE / "g/child/1/child-1.pom"
        path.parent.mkdir(parents=True)
        path.write_text("<project><groupId>g</groupId><artifactId>child</artifactId><version>1</version>"
                        "<parent><groupId>g</groupId><artifactId>parent</artifactId><version>1</version></parent></project>")
        self.pom("g", "parent", "1", licence="Apache-2.0")
        self.assertEqual(generate.maven_licence(("g", "child"), "1", generate.Poms(), CURATED), "Apache-2.0")

    def test_an_unknown_licence_name_fails(self):
        self.pom("g", "a", "1", licence="Some Licence")
        with self.assertRaisesRegex(generate.Failure, "classify it"):
            generate.maven_licence(("g", "a"), "1", generate.Poms(), CURATED)
        self.pom("g", "b", "1", licence=None)
        with self.assertRaisesRegex(generate.Failure, "no licence"):
            generate.maven_licence(("g", "b"), "1", generate.Poms(), CURATED)

    def declared(self, *coordinates, by="p 1.0.0"):
        return {(g, a): {"versions": {v}, "declared_by": {by}} for g, a, v in coordinates}

    def test_a_proprietary_library_never_reaches_the_direct_build(self):
        self.pom("com.android.billingclient", "billing", "8.0.0", licence="Android Software Development Kit License")
        self.pom("androidx.core", "core", "1.0")
        curated = empty_curated()
        libraries, _, terms = generate.android_libraries(
            self.declared(("androidx.core", "core", "1.0")),
            self.declared(("com.android.billingclient", "billing", "8.0.0")),
            generate.Poms(), curated)
        billing = [l for l in libraries if l["coordinate"] == "com.android.billingclient:billing"][0]
        self.assertEqual((billing["flavor"], billing["terms"]), ("store", "LicenseRef-Android-SDK-License"))
        self.assertIn("LicenseRef-Android-SDK-License", terms)
        with self.assertRaisesRegex(generate.Failure, "would ship in the direct build"):
            generate.android_libraries(self.declared(("com.android.billingclient", "billing", "8.0.0")), {},
                                       generate.Poms(), curated)

    def test_a_non_apache_library_needs_its_notice(self):
        self.pom("g", "proto", "1", licence="BSD-3-Clause")
        curated = empty_curated()
        with self.assertRaisesRegex(generate.Failure, "add its notice"):
            generate.android_libraries(self.declared(("g", "proto", "1")), {}, generate.Poms(), curated)
        curated["maven_notices"] = {"g:proto": {"text": "protobuf", "source": "https://example/protobuf/tree/v1"}}
        libraries, texts, _ = generate.android_libraries(self.declared(("g", "proto", "1")), {},
                                                         generate.Poms(), curated)
        self.assertEqual(libraries[0]["text"], "protobuf")
        self.assertEqual(libraries[0]["source"], "https://example/protobuf/tree/v1")
        self.assertIn("Google Inc.", texts["protobuf"])


if __name__ == "__main__":
    unittest.main()
