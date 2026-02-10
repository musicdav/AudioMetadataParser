#!/usr/bin/env python3
import json
import math
import os
import re
import sys
import hashlib
from collections import defaultdict

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKSPACE_ROOT = os.path.dirname(REPO_ROOT)
DATA_DIR = os.path.join(WORKSPACE_ROOT, "tests", "data")
TESTS_DIR = os.path.join(WORKSPACE_ROOT, "tests")
MUTAGEN_DIR = os.path.join(WORKSPACE_ROOT, "mutagen")
OUTPUT_DIR = os.path.join(REPO_ROOT, "Example", "Tests", "Fixtures", "golden")

INCLUDED_TEST_FILES = {
    "test_mp3.py", "test_id3.py", "test_flac.py", "test_mp4.py", "test_wave.py",
    "test_aiff.py", "test_asf.py", "test_apev2.py", "test_aac.py", "test_ac3.py",
    "test_dsf.py", "test_dsdiff.py", "test_musepack.py", "test_wavpack.py", "test_tak.py",
    "test_monkeysaudio.py", "test_trueaudio.py", "test_optimfrog.py", "test_ogg.py",
    "test_oggvorbis.py", "test_oggopus.py", "test_oggspeex.py", "test_oggtheora.py",
    "test_oggflac.py", "test_smf.py",
}

sys.path.insert(0, WORKSPACE_ROOT)
sys.path.insert(0, MUTAGEN_DIR)

try:
    import mutagen  # type: ignore
except Exception as exc:  # pragma: no cover
    raise SystemExit(f"failed to import mutagen from {MUTAGEN_DIR}: {exc}")


def parse_referenced_files():
    mapping = defaultdict(list)
    found = set()

    patterns = [
        re.compile(r"os\.path\.join\(DATA_DIR,\s*['\"]([^'\"]+)['\"]\)"),
        re.compile(r"DATA_DIR\s*,\s*['\"]([^'\"]+)['\"]"),
    ]

    for test_file in sorted(INCLUDED_TEST_FILES):
        path = os.path.join(TESTS_DIR, test_file)
        if not os.path.exists(path):
            continue
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()

        for pat in patterns:
            for m in pat.finditer(text):
                name = m.group(1)
                if name in ("does",):
                    continue
                abs_path = os.path.join(DATA_DIR, name)
                if os.path.isfile(abs_path):
                    found.add(name)
                    mapping[name].append(test_file)

    return sorted(found), mapping


def format_from_filename(name: str):
    ext = os.path.splitext(name)[1].lower().lstrip(".")
    if ext == "mp3":
        return "mp3"
    if ext == "flac":
        return "flac"
    if ext in {"m4a", "m4b", "m4p", "mp4", "3g2"}:
        return "m4a" if ext in {"m4a", "m4b", "m4p", "3g2"} else "mp4"
    if ext in {"wav", "wave"}:
        return "wave"
    if ext in {"aif", "aiff", "aifc"}:
        return "aiff"
    if ext in {"asf", "wma"}:
        return "asf"
    if ext in {"apev2"}:
        return "apev2"
    if ext in {"mpc"}:
        return "musepack"
    if ext in {"wv"}:
        return "wavpack"
    if ext in {"tak"}:
        return "tak"
    if ext in {"dsf"}:
        return "dsf"
    if ext in {"dff", "dsdiff"}:
        return "dsdiff"
    if ext in {"aac"}:
        return "aac"
    if ext in {"ac3"}:
        return "ac3"
    if ext in {"eac3"}:
        return "eac3"
    if ext in {"ogg", "oga", "opus", "spx", "oggtheora", "oggflac", "ogv"}:
        return "ogg"
    if ext in {"tta"}:
        return "trueAudio"
    if ext in {"ofr", "ofs"}:
        return "optimFrog"
    if ext in {"mid", "smf"}:
        return "smf"
    if ext in {"ape"}:
        return "monkeysAudio"
    if ext in {"id3"}:
        return "id3"
    return "unknown"


def safe_number(value):
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return int(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            return None
        return float(value)
    try:
        v = float(value)
        if math.isfinite(v):
            if abs(v - int(v)) < 1e-9:
                return int(v)
            return v
    except Exception:
        return None
    return None


def normalize_tag_value(value):
    if hasattr(value, "imageformat"):
        raw = bytes(value)
        return {
            "kind": "binary",
            "value": {
                "size": len(raw),
                "sha256": hashlib.sha256(raw).hexdigest(),
            },
        }

    if hasattr(value, "text"):
        try:
            texts = [str(x) for x in value.text]
            return {"kind": "text", "value": texts}
        except Exception:
            pass

    if isinstance(value, bytes):
        return {
            "kind": "binary",
            "value": {
                "size": len(value),
                "sha256": hashlib.sha256(value).hexdigest(),
            },
        }

    if isinstance(value, (list, tuple)):
        if value and all(isinstance(x, (bytes, bytearray, memoryview)) for x in value):
            blobs = [bytes(x) for x in value]
            joined = b"".join(blobs)
            return {
                "kind": "binary",
                "value": {
                    "size": len(joined),
                    "sha256": hashlib.sha256(joined).hexdigest(),
                },
            }
        if all(isinstance(x, (str, bytes, int, float, bool)) for x in value):
            converted = []
            for x in value:
                if isinstance(x, bytes):
                    converted.append(x.decode("utf-8", "replace"))
                else:
                    converted.append(str(x))
            return {"kind": "text", "value": converted}

    if isinstance(value, bool):
        return {"kind": "bool", "value": value}

    if isinstance(value, int):
        return {"kind": "int", "value": value}

    if isinstance(value, float):
        if math.isfinite(value):
            return {"kind": "double", "value": value}

    text = str(value)
    if text:
        return {"kind": "text", "value": [text]}

    return None


def collect_tags(audio):
    tags = {}
    wanted_prefixes = (
        "T", "TITLE", "ARTIST", "ALBUM", "GENRE", "COMMENT",
        "\\xa9", "covr", "trkn", "disk", "tmpo", "cpil", "purl",
    )

    source = getattr(audio, "tags", None)
    if source is None:
        return tags

    items = []
    if hasattr(source, "items"):
        try:
            items = list(source.items())
        except Exception:
            items = []

    for key, value in items[:120]:
        key_str = str(key)
        if not key_str:
            continue
        if not key_str.startswith(wanted_prefixes):
            upper = key_str.upper()
            if upper not in {"TITLE", "ARTIST", "ALBUM", "GENRE", "COMMENT"}:
                continue
        normalized = normalize_tag_value(value)
        if normalized:
            tags[key_str] = normalized

    return tags


def collect_extensions(audio):
    ext = {}
    info = getattr(audio, "info", None)
    if info is None:
        return ext

    attrs = [
        "version", "layer", "bitrate_mode", "encoder_info", "codec",
        "codec_name", "codec_description", "track_gain", "track_peak",
        "album_gain", "album_peak", "title_gain", "title_peak",
    ]
    for name in attrs:
        if hasattr(info, name):
            value = getattr(info, name)
            if value is None:
                continue
            if isinstance(value, (int, bool)):
                ext[name] = {"kind": "int", "value": int(value)}
            elif isinstance(value, float):
                if math.isfinite(value):
                    ext[name] = {"kind": "double", "value": float(value)}
            else:
                ext[name] = {"kind": "text", "value": [str(value)]}

    return ext


def build_case(filename, source_tests):
    abs_path = os.path.join(DATA_DIR, filename)
    case = {
        "caseId": os.path.splitext(filename)[0],
        "sourcePythonTest": sorted(set(source_tests)),
        "inputFile": filename,
        "expectedFormat": format_from_filename(filename),
        "expectedCoreInfo": {
            "length": None,
            "bitrate": None,
            "sampleRate": None,
            "channels": None,
            "bitsPerSample": None,
        },
        "expectedTags": {},
        "expectedExtensions": {},
        "expectedError": None,
    }

    try:
        audio = mutagen.File(abs_path)
    except Exception as exc:
        case["expectedError"] = {
            "code": "invalidHeader",
            "message": str(exc),
        }
        return case

    if audio is None:
        case["expectedError"] = {
            "code": "unsupportedFormat",
            "message": "mutagen returned None",
        }
        return case

    info = getattr(audio, "info", None)
    if info is not None:
        case["expectedCoreInfo"]["length"] = safe_number(getattr(info, "length", None))
        case["expectedCoreInfo"]["bitrate"] = safe_number(getattr(info, "bitrate", None))
        case["expectedCoreInfo"]["sampleRate"] = safe_number(getattr(info, "sample_rate", None))
        case["expectedCoreInfo"]["channels"] = safe_number(getattr(info, "channels", None))
        case["expectedCoreInfo"]["bitsPerSample"] = safe_number(getattr(info, "bits_per_sample", None))

    case["expectedTags"] = collect_tags(audio)
    case["expectedExtensions"] = collect_extensions(audio)
    return case


def main():
    files, mapping = parse_referenced_files()
    if not files:
        raise SystemExit("no referenced fixtures found")

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    by_format = defaultdict(list)
    for filename in files:
        case = build_case(filename, mapping.get(filename, []))
        by_format[case["expectedFormat"]].append(case)

    index = []
    for fmt, cases in sorted(by_format.items()):
        cases.sort(key=lambda x: x["inputFile"])
        out_name = f"{fmt}.json"
        out_path = os.path.join(OUTPUT_DIR, out_name)
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump({"format": fmt, "cases": cases}, f, indent=2, ensure_ascii=False)
        index.append({"format": fmt, "file": out_name, "count": len(cases)})

    with open(os.path.join(OUTPUT_DIR, "index.json"), "w", encoding="utf-8") as f:
        json.dump({"files": index}, f, indent=2, ensure_ascii=False)

    print(f"generated {sum(x['count'] for x in index)} cases across {len(index)} files")


if __name__ == "__main__":
    main()
