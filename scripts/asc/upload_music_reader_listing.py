#!/usr/bin/env python3
"""Prepare the App Store listing of AI Music Radar (com.ragnus.pnge, ASC app 6818838017, version 1.0, en-US).

Listing prep only. This script NEVER creates a review submission and never submits for review
(that is .github/workflows/asc-submit-app-store.yml, run by hand by the owner).

Sources (fastlane deliver layout):
  docs/asc/metadata/en-US/{name,subtitle,description,keywords,promotional_text,
                           support_url,marketing_url,privacy_url}.txt
  docs/asc/metadata/{copyright,primary_category,secondary_category}.txt
  docs/asc/metadata/review_information/{first_name,last_name,phone_number,email_address,demo_required}.txt
  docs/asc/screenshots/en-US/iphone-69-*.png  -> APP_IPHONE_67          (1320x2868)
  docs/asc/screenshots/en-US/ipad-13-*.png    -> APP_IPAD_PRO_3GEN_129  (2064x2752)

Steps: metadata + URLs + categories + copyright + App Review contact + age rating (only fields
still unset -> NONE/false) + export compliance for BUILD_NUMBER + attach BUILD_NUMBER to the
version + (UPLOAD_SCREENSHOTS=true) replace screenshots, then a read-only verification that exits
1 if anything is off. VERIFY_ONLY=true skips every write.

Env: APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID, APP_STORE_CONNECT_API_KEY_P8,
     BUNDLE_ID (com.ragnus.pnge), VERSION_STRING (1.0), BUILD_NUMBER (15),
     UPLOAD_SCREENSHOTS (true/false), VERIFY_ONLY (true/false), SKIP_IF_NOT_EDITABLE (true/false)
Used by asc-music-reader-upload.yml and, before submitting, by asc-submit-app-store.yml (sync_listing).
"""
from __future__ import annotations
import hashlib, os, struct, sys, time
from pathlib import Path
import jwt, requests

ROOT = Path(__file__).resolve().parents[2]
META = ROOT / "docs/asc/metadata"
LOC_DIR = META / "en-US"
SHOTS = ROOT / "docs/asc/screenshots/en-US"
LOCALE = "en-US"
SHOT_TYPES = {"iphone-69": ("APP_IPHONE_67", (1320, 2868)), "ipad-13": ("APP_IPAD_PRO_3GEN_129", (2064, 2752))}
BASE = "https://api.appstoreconnect.apple.com"
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}

BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.ragnus.pnge").strip()
VERSION = os.environ.get("VERSION_STRING", "1.0").strip()
BUILD_NUMBER = os.environ.get("BUILD_NUMBER", "15").strip()
# Submit workflow sync: a version still in review is left alone (the submit step cancels + resubmits)
SKIP_IF_NOT_EDITABLE = os.environ.get("SKIP_IF_NOT_EDITABLE", "false").strip().lower() == "true"
UPLOAD_SHOTS = os.environ.get("UPLOAD_SCREENSHOTS", "true").strip().lower() == "true"
VERIFY_ONLY = os.environ.get("VERIFY_ONLY", "false").strip().lower() == "true"
_tok = {"v": None, "t": 0}


def token() -> str:
    now = int(time.time())
    if _tok["v"] and now - _tok["t"] < 600:
        return _tok["v"]
    p8 = os.environ["APP_STORE_CONNECT_API_KEY_P8"].replace("\\n", "\n").strip()
    _tok["v"] = jwt.encode({"iss": os.environ["APP_STORE_CONNECT_ISSUER_ID"].strip(), "iat": now,
                            "exp": now + 1100, "aud": "appstoreconnect-v1"}, p8, algorithm="ES256",
                           headers={"kid": os.environ["APP_STORE_CONNECT_KEY_ID"].strip()})
    _tok["t"] = now
    return _tok["v"]


class ApiError(Exception):
    pass


def api(method, path, body=None, ok404=False):
    assert "reviewSubmission" not in path and "appStoreVersionSubmission" not in path, "never submits"
    if VERIFY_ONLY and method != "GET":
        raise SystemExit(f"VERIFY_ONLY but tried {method} {path}")
    r = requests.request(method, path if path.startswith("http") else BASE + path, json=body,
                         headers={"Authorization": "Bearer " + token()}, timeout=120)
    if ok404 and r.status_code == 404:
        return None
    if r.status_code >= 300:
        raise ApiError(f"{method} {path} -> {r.status_code}: {r.text[:1500]}")
    return r.json() if r.text else {}


def txt(p: Path) -> str:
    return p.read_text().strip() if p.exists() else ""


def png_size(p: Path):
    b = p.read_bytes()[:24]
    return struct.unpack(">II", b[16:24])


def main():
    L = {k: txt(LOC_DIR / f"{k}.txt") for k in ("name", "subtitle", "description", "keywords", "promotional_text",
                                                  "support_url", "marketing_url", "privacy_url")}
    copyright_ = txt(META / "copyright.txt")
    cat1, cat2 = txt(META / "primary_category.txt"), txt(META / "secondary_category.txt")
    R = {k: txt(META / "review_information" / f"{k}.txt") for k in ("first_name", "last_name", "phone_number", "email_address", "demo_required")}
    blob = " ".join(L.values()).lower()
    for banned in ("sweden", "c418", "minecraft", "grok"):
        assert banned not in blob, f"metadata mentions {banned!r}"
    for k, lim in (("name", 30), ("subtitle", 30), ("promotional_text", 170), ("keywords", 100), ("description", 4000)):
        assert 0 < len(L[k]) <= lim, f"{k}: {len(L[k])} chars (limit {lim})"
    shots = {}
    for prefix, (dtype, size) in SHOT_TYPES.items():
        files = sorted(SHOTS.glob(f"{prefix}-*.png"))
        for f in files:
            assert png_size(f) == size, f"{f.name} is {png_size(f)}, want {size}"
        shots[dtype] = files
    print("screenshots in repo:", {k: [f.name for f in v] for k, v in shots.items()})

    app = api("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"][0]
    app_id = app["id"]
    print("APP", app_id, app["attributes"].get("name"), BUNDLE_ID)
    vers = api("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&filter[versionString]={VERSION}")["data"]
    if not vers:
        raise SystemExit(f"version {VERSION} not found")
    ver = vers[0]
    vstate = ver["attributes"].get("appVersionState") or ver["attributes"].get("appStoreState")
    print("VERSION", ver["id"], VERSION, ver["attributes"].get("appStoreState"), ver["attributes"].get("appVersionState"))
    infos = api("GET", f"/v1/apps/{app_id}/appInfos")["data"]
    info = next((i for i in infos if (i["attributes"].get("state") or i["attributes"].get("appStoreState")) not in ("READY_FOR_DISTRIBUTION", "READY_FOR_SALE")), infos[0])
    builds = api("GET", f"/v1/builds?filter[app]={app_id}&filter[version]={BUILD_NUMBER}&limit=10")["data"]
    build = next((b for b in builds if not b["attributes"].get("expired")), None)
    if not build:
        raise SystemExit(f"build {BUILD_NUMBER} not found")
    print("BUILD", build["id"], BUILD_NUMBER, build["attributes"].get("processingState"), "encryption=", build["attributes"].get("usesNonExemptEncryption"))

    warnings = []
    if not VERIFY_ONLY:
        if ver["attributes"].get("appStoreState") not in EDITABLE and vstate not in EDITABLE:
            if SKIP_IF_NOT_EDITABLE:
                print(f"WARNING: version {VERSION} not editable ({vstate}); listing sync skipped, nothing written")
                return
            raise SystemExit(f"version {VERSION} not editable ({vstate}); nothing written")
        write(app_id, ver, info, build, L, copyright_, cat1, cat2, R, shots, warnings)
    ok = verify(app_id, app, ver["id"], info["id"], L, copyright_, cat1, R, shots, warnings)
    print("\nWARNINGS:" if warnings else "\nno warnings", *warnings, sep="\n  ")
    if not ok:
        raise SystemExit("VERIFY FAILED")
    print("VERIFY OK")


def write(app_id, ver, info, build, L, copyright_, cat1, cat2, R, shots, warnings):
    vid = ver["id"]
    # App info localization: name, subtitle, privacy policy URL
    locs = api("GET", f"/v1/appInfos/{info['id']}/appInfoLocalizations")["data"]
    loc = next(l for l in locs if l["attributes"]["locale"] == LOCALE)
    attrs = {"name": L["name"], "subtitle": L["subtitle"], "privacyPolicyUrl": L["privacy_url"]}
    api("PATCH", f"/v1/appInfoLocalizations/{loc['id']}", {"data": {"type": "appInfoLocalizations", "id": loc["id"], "attributes": attrs}})
    print("appInfoLocalization:", list(attrs))
    rel = {"primaryCategory": {"data": {"type": "appCategories", "id": cat1}}}
    if cat2:
        rel["secondaryCategory"] = {"data": {"type": "appCategories", "id": cat2}}
    api("PATCH", f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": rel}})
    print("categories:", cat1, cat2)

    # Age rating: only fields still unset -> NONE / false (4+)
    ard = api("GET", f"/v1/appInfos/{info['id']}/ageRatingDeclaration", ok404=True)
    if ard and ard.get("data"):
        a = ard["data"]["attributes"]
        string_fields = ["alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons",
                         "horrorOrFearThemes", "matureOrSuggestiveThemes", "medicalOrTreatmentInformation",
                         "profanityOrCrudeHumor", "sexualContentGraphicAndNudity", "sexualContentOrNudity",
                         "violenceCartoonOrFantasy", "violenceRealistic", "violenceRealisticProlongedGraphicOrSadistic"]
        bool_fields = ["advertising", "gambling", "healthOrWellnessTopics", "lootBox", "messagingAndChat", "parentalControls",
                       "ageAssurance", "socialMedia", "unrestrictedWebAccess", "userGeneratedContent"]
        todo = {k: "NONE" for k in string_fields if a.get(k) is None}
        todo.update({k: False for k in bool_fields if a.get(k) is None})
        print("ageRating current:", a)
        if todo:
            try:
                api("PATCH", f"/v1/ageRatingDeclarations/{ard['data']['id']}", {"data": {"type": "ageRatingDeclarations", "id": ard["data"]["id"], "attributes": todo}})
                print("ageRating set:", sorted(todo))
            except ApiError as e:
                print("ageRating bulk patch failed, per field:", e)
                for k, v in todo.items():
                    try:
                        api("PATCH", f"/v1/ageRatingDeclarations/{ard['data']['id']}", {"data": {"type": "ageRatingDeclarations", "id": ard["data"]["id"], "attributes": {k: v}}})
                    except ApiError as e2:
                        warnings.append(f"age rating {k}={v} rejected: {e2}")
        else:
            print("ageRating: all fields already set")
    else:
        warnings.append("no ageRatingDeclaration found on appInfo")

    # Version: copyright
    api("PATCH", f"/v1/appStoreVersions/{vid}", {"data": {"type": "appStoreVersions", "id": vid, "attributes": {"copyright": copyright_}}})
    print("copyright:", copyright_)

    # Version localization: description, keywords, promo, support + marketing URL
    vlocs = api("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]
    vloc = next((l for l in vlocs if l["attributes"]["locale"] == LOCALE), None)
    vattrs = {"description": L["description"], "keywords": L["keywords"], "promotionalText": L["promotional_text"],
              "supportUrl": L["support_url"]}
    if L["marketing_url"]:
        vattrs["marketingUrl"] = L["marketing_url"]
    elif vloc and vloc["attributes"].get("marketingUrl"):
        vattrs["marketingUrl"] = None  # blank in repo -> clear
    if vloc:
        api("PATCH", f"/v1/appStoreVersionLocalizations/{vloc['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": vloc["id"], "attributes": vattrs}})
    else:
        vloc = api("POST", "/v1/appStoreVersionLocalizations", {"data": {"type": "appStoreVersionLocalizations", "attributes": {"locale": LOCALE, **vattrs},
                   "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})["data"]
    print("appStoreVersionLocalization:", list(vattrs))

    # App Review contact
    rd = api("GET", f"/v1/appStoreVersions/{vid}/appStoreReviewDetail", ok404=True)
    rattrs = {"contactFirstName": R["first_name"], "contactLastName": R["last_name"], "contactPhone": R["phone_number"],
              "contactEmail": R["email_address"], "demoAccountRequired": R["demo_required"].lower() == "true"}
    if rd and rd.get("data"):
        api("PATCH", f"/v1/appStoreReviewDetails/{rd['data']['id']}", {"data": {"type": "appStoreReviewDetails", "id": rd["data"]["id"], "attributes": rattrs}})
    else:
        api("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": rattrs,
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
    print("review contact:", rattrs)

    # Export compliance + attach build
    ba = build["attributes"]
    if ba.get("processingState") != "VALID":
        raise SystemExit(f"build {BUILD_NUMBER} is {ba.get('processingState')}, not VALID")
    if ba.get("usesNonExemptEncryption") is not False:
        api("PATCH", f"/v1/builds/{build['id']}", {"data": {"type": "builds", "id": build["id"], "attributes": {"usesNonExemptEncryption": False}}})
        print("export compliance: usesNonExemptEncryption=false set")
    else:
        print("export compliance: already cleared")
    api("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build", {"data": {"type": "builds", "id": build["id"]}})
    print("attached build", BUILD_NUMBER, build["id"], "to version", VERSION)

    if UPLOAD_SHOTS:
        replace_screenshots(vloc["id"], shots, warnings)


def upload_one(set_id, f: Path) -> str:
    data = f.read_bytes()
    shot = api("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots", "attributes": {"fileName": f.name, "fileSize": len(data)},
               "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})["data"]
    for op in shot["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]: op["offset"] + op["length"]]
        h = {x["name"]: x["value"] for x in op.get("requestHeaders", [])}
        requests.request(op["method"], op["url"], data=chunk, headers=h, timeout=180).raise_for_status()
    api("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    for _ in range(60):
        st = (api("GET", f"/v1/appScreenshots/{shot['id']}")["data"]["attributes"].get("assetDeliveryState") or {})
        if st.get("state") in ("COMPLETE", "FAILED"):
            break
        time.sleep(5)
    if st.get("state") != "COMPLETE":
        raise SystemExit(f"screenshot {f.name} delivery {st}")
    print("  uploaded", f.name, shot["id"], st.get("state"))
    return shot["id"]


def replace_screenshots(vloc_id, shots, warnings):
    sets = api("GET", f"/v1/appStoreVersionLocalizations/{vloc_id}/appScreenshotSets?limit=50")["data"]
    for s in sets:  # sets for other display types would keep stale frames: remove them
        dt = s["attributes"]["screenshotDisplayType"]
        if dt not in shots or not shots[dt]:
            n = len(api("GET", f"/v1/appScreenshotSets/{s['id']}/appScreenshots")["data"])
            api("DELETE", f"/v1/appScreenshotSets/{s['id']}")
            print(f"deleted stale set {dt} ({n} screenshots)")
    for dtype, files in shots.items():
        if not files:
            continue
        sset = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == dtype), None)
        if sset is None:
            sset = api("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": dtype},
                       "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": vloc_id}}}}})["data"]
        old = [x["id"] for x in api("GET", f"/v1/appScreenshotSets/{sset['id']}/appScreenshots")["data"]]
        print(f"{dtype}: set {sset['id']}, replacing {len(old)} old screenshot(s)")
        for oid in old:  # Apple caps a set at 10; delete first, then upload in order
            api("DELETE", f"/v1/appScreenshots/{oid}")
        new = [upload_one(sset["id"], f) for f in files]
        api("PATCH", f"/v1/appScreenshotSets/{sset['id']}/relationships/appScreenshots",
            {"data": [{"type": "appScreenshots", "id": i} for i in new]})
        print(f"{dtype}: order set", [f.name for f in files])


def verify(app_id, app, vid, info_id, L, copyright_, cat1, R, shots, warnings) -> bool:
    print("\n==== VERIFY (read-only) ====")
    ok = True

    def check(label, cond, detail=""):
        nonlocal ok
        ok &= bool(cond)
        print(f"[{'OK ' if cond else 'BAD'}] {label} {detail}")

    v = api("GET", f"/v1/appStoreVersions/{vid}")["data"]["attributes"]
    check("version state (editable)", v.get("appStoreState") in EDITABLE or v.get("appVersionState") in EDITABLE,
          f"{VERSION} appStoreState={v.get('appStoreState')} appVersionState={v.get('appVersionState')}")
    check("copyright", v.get("copyright") == copyright_, repr(v.get("copyright")))
    b = (api("GET", f"/v1/appStoreVersions/{vid}/build", ok404=True) or {}).get("data")
    check("attached build", b and b["attributes"].get("version") == BUILD_NUMBER,
          f"{b and b['attributes'].get('version')} {b and b['attributes'].get('processingState')} encryption={b and b['attributes'].get('usesNonExemptEncryption')}")
    check("export compliance", b and b["attributes"].get("usesNonExemptEncryption") is False)
    vloc = next((l for l in api("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"] if l["attributes"]["locale"] == LOCALE), None)
    va = vloc["attributes"] if vloc else {}
    check("description", va.get("description") == L["description"], f"{len(va.get('description') or '')} chars")
    check("keywords", va.get("keywords") == L["keywords"])
    check("promotional text", va.get("promotionalText") == L["promotional_text"])
    check("support URL", va.get("supportUrl") == L["support_url"], repr(va.get("supportUrl")))
    check("marketing URL", (va.get("marketingUrl") or "") == L["marketing_url"], repr(va.get("marketingUrl")))
    il = next(l for l in api("GET", f"/v1/appInfos/{info_id}/appInfoLocalizations")["data"] if l["attributes"]["locale"] == LOCALE)["attributes"]
    check("name/subtitle", il.get("name") == L["name"] and il.get("subtitle") == L["subtitle"], f"{il.get('name')!r} / {il.get('subtitle')!r}")
    check("privacy policy URL", il.get("privacyPolicyUrl") == L["privacy_url"], repr(il.get("privacyPolicyUrl")))
    pc = (api("GET", f"/v1/appInfos/{info_id}/primaryCategory", ok404=True) or {}).get("data")
    sc = (api("GET", f"/v1/appInfos/{info_id}/secondaryCategory", ok404=True) or {}).get("data")
    check("primary category", pc and pc["id"] == cat1, f"{pc and pc['id']} / secondary {sc and sc['id']}")
    ard = (api("GET", f"/v1/appInfos/{info_id}/ageRatingDeclaration", ok404=True) or {}).get("data")
    if ard:
        a = ard["attributes"]
        core = ["alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "horrorOrFearThemes", "matureOrSuggestiveThemes",
                "medicalOrTreatmentInformation", "profanityOrCrudeHumor", "sexualContentGraphicAndNudity", "sexualContentOrNudity",
                "violenceCartoonOrFantasy", "violenceRealistic", "violenceRealisticProlongedGraphicOrSadistic", "gambling", "unrestrictedWebAccess"]
        unset = [k for k in core if a.get(k) is None]
        nonzero = {k: x for k, x in a.items() if x not in (None, "NONE", False) and k not in ("developerAgeRatingInfoUrl", "gracRatingClassificationNumber")}
        other_unset = [k for k, x in a.items() if x is None and k not in core]
        check("age rating (core questions)", not unset, f"unset={unset} non-NONE/false={nonzero}")
        print(f"[INFO] age rating other unset fields: {other_unset}")
    else:
        check("age rating declaration exists", False)
    rd = ((api("GET", f"/v1/appStoreVersions/{vid}/appStoreReviewDetail", ok404=True) or {}).get("data") or {}).get("attributes", {})
    check("App Review contact", rd.get("contactFirstName") == R["first_name"] and rd.get("contactLastName") == R["last_name"]
          and rd.get("contactPhone") == R["phone_number"] and rd.get("contactEmail") == R["email_address"],
          f"{rd.get('contactFirstName')} {rd.get('contactLastName')} {rd.get('contactPhone')} {rd.get('contactEmail')} demo={rd.get('demoAccountRequired')}")
    if vloc:
        sets = api("GET", f"/v1/appStoreVersionLocalizations/{vloc['id']}/appScreenshotSets?limit=50")["data"]
        seen = {}
        for s in sets:
            dt = s["attributes"]["screenshotDisplayType"]
            items = api("GET", f"/v1/appScreenshotSets/{s['id']}/appScreenshots")["data"]
            desc = []
            for it in items:
                ia = it["attributes"]
                img = ia.get("imageAsset") or {}
                desc.append((ia.get("fileName"), img.get("width"), img.get("height"), (ia.get("assetDeliveryState") or {}).get("state")))
            seen[dt] = desc
            print(f"      SET {dt}: {desc}")
        for dtype, files in shots.items():
            size = next(sz for dt, sz in SHOT_TYPES.values() if dt == dtype)
            want = [(f.name, *size) for f in files]
            got = [(n, w, h) for n, w, h, st in seen.get(dtype, [])]
            check(f"screenshots {dtype}", got == want and all(st == "COMPLETE" for *_, st in seen.get(dtype, [])), f"{len(got)} present, want {len(want)} in order")
        extra = [d for d in seen if d not in shots or not shots[d]]
        check("no stale screenshot sets", not extra, str(extra))
    # Read-only extras the submit needs but this script does not set
    aa = api("GET", f"/v1/apps/{app_id}")["data"]["attributes"]
    crd = aa.get("contentRightsDeclaration")
    print(f"[INFO] contentRightsDeclaration={crd}")
    if not crd:
        warnings.append("Content Rights (third-party content) declaration is unset: set it in App Store Connect > App Information")
    ps = api("GET", f"/v1/apps/{app_id}/appPriceSchedule", ok404=True)
    print(f"[INFO] appPriceSchedule={'set' if ps and ps.get('data') else 'NOT SET'}")
    if not (ps and ps.get("data")):
        warnings.append("Price schedule not set: set Pricing and Availability (e.g. Free) in App Store Connect")
    av = api("GET", f"/v1/apps/{app_id}/appAvailabilityV2", ok404=True)
    print(f"[INFO] appAvailabilityV2={'set' if av and av.get('data') else 'NOT SET'}")
    if not (av and av.get("data")):
        warnings.append("App availability (territories) not set: set in Pricing and Availability")
    return ok


if __name__ == "__main__":
    main()
