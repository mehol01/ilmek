# Builds Localizable.xcstrings for the app and the widget from the keys the compiler
# extracted (.stringsdata) plus tools/translations_en.py. Keys without a translation are
# reported. Language-neutral keys (emoji/format-only) are marked "shouldTranslate": false.
import glob, json, re, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from translations_en import EN

ROOT = os.path.join(os.path.dirname(__file__), "..")
MANUAL = {
    "FRIEND_DAY_COMPLETE": ("%1$@ bugünün tüm ilmeklerini attı 🧶", "%1$@ finished all of today's stitches 🧶"),
    "GROUP_MEMBER_JOINED": ("%1$@ grubuna katıldı", "%1$@ joined your group"),
}

def keys_for(target):
    out = []
    for f in glob.glob(f"{ROOT}/build/Build/Intermediates.noindex/Ilmek.build/Debug-iphoneos/{target}.build/**/*.stringsdata", recursive=True):
        for t, entries in json.load(open(f)).get("tables", {}).items():
            out += [e["key"] for e in entries]
    return sorted(set(out))

def neutral(k):
    return not re.search(r"[A-Za-zÇĞİÖŞÜçğıöşü]{2,}", re.sub(r"%(\d\$)?(lld|@|d)", "", k))

def unit(v): return {"stringUnit": {"state": "translated", "value": v}}

def build(target, path):
    strings, missing = {}, []
    for k in keys_for(target):
        if neutral(k):
            strings[k] = {"shouldTranslate": False}
            continue
        en = EN.get(k)
        if en is None:
            missing.append(k); strings[k] = {}; continue
        if isinstance(en, dict):
            strings[k] = {"localizations": {"en": {"variations": {"plural": {
                "one": unit(en["one"]), "other": unit(en["other"])}}}}}
        else:
            strings[k] = {"localizations": {"en": unit(en)}}
    if target == "Ilmek":
        for k, (tr, en) in MANUAL.items():
            strings[k] = {"extractionState": "manual",
                          "localizations": {"tr": unit(tr), "en": unit(en)}}
    json.dump({"sourceLanguage": "tr", "strings": strings, "version": "1.0"},
              open(path, "w"), ensure_ascii=False, indent=2, sort_keys=True)
    print(f"{target}: {len(strings)} keys, missing: {missing}")

build("Ilmek", f"{ROOT}/Ilmek/Localizable.xcstrings")
build("IlmekWidgetExtension", f"{ROOT}/IlmekWidget/Localizable.xcstrings")
