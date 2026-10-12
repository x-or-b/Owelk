#!/usr/bin/env python3
"""Writes translations/owelk_hangul.ts: every interface string spelled out in Hangul ("Settings" → "세팅스").

The words come from tools/hangul_words.tsv (English word, Hangul). Run after adding or changing interface
text (qsTr("…") in QML and JS, ui("…") in C++):

    python3 tools/hangul.py            write the .ts (the build turns it into the app's .qm)
    python3 tools/hangul.py --missing  list words that have no Hangul spelling yet

A word without a spelling stays in English; a string can be left as it is by listing it in
tools/hangul_keep.txt (codes, sample text and the like).
"""
import html
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORDS = ROOT / "tools" / "hangul_words.tsv"
KEEP = ROOT / "tools" / "hangul_keep.txt"
OUT = ROOT / "translations" / "owelk_hangul.ts"

STRING = r'"((?:[^"\\\n]|\\.)*)"'


def unescape(text):
    # The escapes QML, JS and C++ string literals use here.
    return json.loads('"' + text.replace("\\'", "'") + '"')


def sources():
    found = {}
    for path in sorted(list((ROOT / "qml").glob("*.qml")) + list((ROOT / "qml").glob("*.js"))
                       + list((ROOT / "style").glob("*.qml"))):
        for literal in re.findall(r'qsTr\(' + STRING + r'\)', path.read_text(encoding="utf-8")):
            found.setdefault(path.stem, set()).add(unescape(literal))
    for path in sorted(list((ROOT / "src").rglob("*.cpp")) + list((ROOT / "src").rglob("*.h"))):
        for call in re.findall(r'\bui\(((?:\s*' + STRING + r')+)\s*\)', path.read_text(encoding="utf-8")):
            text = "".join(unescape(part) for part in re.findall(STRING, call[0]))
            found.setdefault("Owelk", set()).add(text)
    return found


def words():
    table = {}
    if WORDS.exists():
        for line in WORDS.read_text(encoding="utf-8").splitlines():
            if line.strip() and not line.startswith("#"):
                english, hangul = line.split("\t")
                table[english.lower()] = hangul
    return table


TOKEN = re.compile(r"%\d+|[A-Za-z]+(?:['’][A-Za-z]+)*|[^A-Za-z%]+|%")


# Left as written: `commands`, <markup> and &entities;.
VERBATIM = re.compile(r"(`[^`]*`|<[^>]*>|&[a-z]+;)")


def spell(text, table, missing):
    return "".join(part if VERBATIM.fullmatch(part) else spell_words(part, table, missing)
                   for part in VERBATIM.split(text) if part)


def spell_words(text, table, missing):
    out = []
    for token in TOKEN.findall(text):
        if re.match(r"[A-Za-z]", token):
            hangul = table.get(token.lower())
            if hangul is None:
                missing.add(token.lower())
                out.append(token)
            else:
                out.append(hangul)
        else:
            out.append(token)
    return "".join(out)


def main():
    table = words()
    keep = set(KEEP.read_text(encoding="utf-8").splitlines()) if KEEP.exists() else set()
    missing = set()
    lines = ['<?xml version="1.0" encoding="utf-8"?>', "<!DOCTYPE TS>", '<TS version="2.1" language="ko">']
    for context, texts in sorted(sources().items()):
        lines += ["<context>", "    <name>%s</name>" % context]
        for text in sorted(texts):
            translation = text if text in keep else spell(text, table, missing)
            lines += ["    <message>", "        <source>%s</source>" % html.escape(text, quote=False),
                      "        <translation>%s</translation>" % html.escape(translation, quote=False), "    </message>"]
        lines.append("</context>")
    lines.append("</TS>")
    if "--missing" in sys.argv:
        print("\n".join(sorted(missing)))
        return
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("%d strings, %d words without a spelling" % (sum(len(t) for t in sources().values()), len(missing)))


if __name__ == "__main__":
    main()
