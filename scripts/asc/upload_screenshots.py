#!/usr/bin/env python3
"""Upload AI Music Radar screenshots to App Store Connect, then read everything back and verify.

1. IAP review screenshots (docs/paywall/mockups/02-paywall.png, 1320x2868) for
   com.ragnus.pnge.pro.monthly / .pro.yearly (subscriptionAppStoreReviewScreenshots) and
   com.ragnus.pnge.lifetime (inAppPurchaseAppStoreReviewScreenshots). A product's existing
   COMPLETE screenshot is kept. A FAILED or missing one is (re)uploaded.
2. App Store screenshots for the editable en-US version localization:
     docs/asc/screenshots/en-US/iphone-69-*.png -> APP_IPHONE_67          (6.9")
     docs/asc/screenshots/en-US/ipad-13-*.png   -> APP_IPAD_PRO_3GEN_129  (13")
   Existing screenshots in those two sets are deleted and replaced, in filename order. Other sets are left alone.
3. Verify: every asset's assetDeliveryState is COMPLETE (FAILED gets retried up to 3x), the counts and order match,
   and each product's state is READY_TO_SUBMIT (polled).
Env: APP_STORE_CONNECT_KEY_ID / _ISSUER_ID / _API_KEY_P8, DRY_RUN=true|false.
"""
import hashlib, json, os, sys, time
from pathlib import Path
import jwt, requests

APP = "6818838017"
ROOT = Path(__file__).resolve().parents[2]
REVIEW_SHOT = ROOT / "docs/paywall/mockups/02-paywall.png"
SHOT_DIR = ROOT / "docs/asc/screenshots/en-US"
SETS = {"APP_IPHONE_67": "iphone-69-", "APP_IPAD_PRO_3GEN_129": "ipad-13-"}
SUBS = {"com.ragnus.pnge.pro.monthly": "6818849486", "com.ragnus.pnge.pro.yearly": "6818849180"}
LIFETIME = ("com.ragnus.pnge.lifetime", "6818849838")
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}
DRY = os.environ.get("DRY_RUN", "false") == "true"
_tok = {"t": None, "at": 0}
report, failures = [], []


def token():
    if not _tok["t"] or time.time() - _tok["at"] > 900:
        p8 = os.environ["APP_STORE_CONNECT_API_KEY_P8"].replace("\\n", "\n").strip()
        now = int(time.time())
        _tok["t"] = jwt.encode({"iss": os.environ["APP_STORE_CONNECT_ISSUER_ID"].strip(), "iat": now, "exp": now + 1200,
                                "aud": "appstoreconnect-v1"}, p8, algorithm="ES256",
                               headers={"kid": os.environ["APP_STORE_CONNECT_KEY_ID"].strip()})
        _tok["at"] = time.time()
    return _tok["t"]


def api(method, path, body=None, ok404=False):
    r = requests.request(method, "https://api.appstoreconnect.apple.com" + path, json=body, timeout=120,
                         headers={"Authorization": f"Bearer {token()}"})
    if ok404 and r.status_code == 404:
        return None
    if r.status_code >= 400:
        raise SystemExit(f"{method} {path} -> {r.status_code}: {r.text[:1500]}")
    return r.json() if r.text else {}


def state_of(a):
    return ((a.get("attributes") or {}).get("assetDeliveryState") or {}).get("state")


def put_asset(create_path, rel, f: Path, patch_type):
    """Reserve, upload the parts, commit, and poll until COMPLETE or FAILED. Returns (id, state, errors)."""
    data = f.read_bytes()
    a = api("POST", create_path, {"data": {"type": patch_type, "attributes": {"fileName": f.name, "fileSize": len(data)},
                                           "relationships": rel}})["data"]
    for op in a["attributes"]["uploadOperations"]:
        h = {x["name"]: x["value"] for x in op.get("requestHeaders", [])}
        requests.request(op["method"], op["url"], data=data[op["offset"]: op["offset"] + op["length"]], headers=h,
                         timeout=180).raise_for_status()
    api("PATCH", f"{create_path}/{a['id']}", {"data": {"type": patch_type, "id": a["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    st, errs = poll(f"{create_path}/{a['id']}")
    return a["id"], st, errs


def poll(path, tries=72):
    st, errs = None, None
    for _ in range(tries):
        a = api("GET", path)["data"]
        ad = a["attributes"].get("assetDeliveryState") or {}
        st, errs = ad.get("state"), ad.get("errors")
        if st in ("COMPLETE", "FAILED"):
            break
        time.sleep(5)
    return st, errs


def with_retry(label, fn, delete_path):
    for attempt in range(1, 4):
        aid, st, errs = fn()
        print(f"  {label}: {aid} {st} (attempt {attempt})")
        if st == "COMPLETE":
            return aid
        if errs:
            print(f"    errors: {json.dumps(errs)[:500]}")
        api("DELETE", f"{delete_path}/{aid}")
    failures.append(f"{label}: delivery not COMPLETE after 3 attempts")
    return None


# 1. IAP review screenshots
def review_shots():
    print("== IAP review screenshots ==")
    items = [(pid, sid, f"/v1/subscriptions/{sid}/appStoreReviewScreenshot", "/v1/subscriptionAppStoreReviewScreenshots",
              "subscriptionAppStoreReviewScreenshots", {"subscription": {"data": {"type": "subscriptions", "id": sid}}})
             for pid, sid in SUBS.items()]
    lid = LIFETIME[1]
    items.append((LIFETIME[0], lid, f"/v2/inAppPurchases/{lid}/appStoreReviewScreenshot", "/v1/inAppPurchaseAppStoreReviewScreenshots",
                  "inAppPurchaseAppStoreReviewScreenshots", {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": lid}}}))
    for pid, _id, get_path, base, typ, rel in items:
        cur = (api("GET", get_path, ok404=True) or {}).get("data")
        if cur and state_of(cur) == "COMPLETE":
            print(f"  {pid}: existing {cur['id']} COMPLETE, kept")
            continue
        if cur:
            print(f"  {pid}: existing {cur['id']} {state_of(cur)}, replacing")
            if not DRY:
                api("DELETE", f"{base}/{cur['id']}")
        if DRY:
            print(f"  [dry] {pid}: would upload {REVIEW_SHOT.name}")
            continue
        with_retry(pid, lambda: put_asset(base, rel, REVIEW_SHOT, typ), base)


# 2. App Store screenshots
def store_shots():
    print("== App Store screenshots ==")
    vers = api("GET", f"/v1/apps/{APP}/appStoreVersions?filter[platform]=IOS&limit=20")["data"]
    ed = [v for v in vers if (v["attributes"].get("appVersionState") or v["attributes"].get("appStoreState")) in EDITABLE]
    if not ed:
        raise SystemExit("no editable App Store version: " + ", ".join(
            f"{v['attributes']['versionString']}={v['attributes'].get('appVersionState')}" for v in vers))
    v = ed[0]
    print(f"version {v['attributes']['versionString']} ({v['id']}) {v['attributes'].get('appVersionState')}")
    loc = next((l for l in api("GET", f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations")["data"]
                if l["attributes"]["locale"] == "en-US"), None)
    if not loc:
        raise SystemExit("no en-US appStoreVersionLocalization")
    sets = api("GET", f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets?limit=50")["data"]
    others = [s["attributes"]["screenshotDisplayType"] for s in sets if s["attributes"]["screenshotDisplayType"] not in SETS]
    if others:
        print(f"other sets left untouched: {others}")
    for dtype, prefix in SETS.items():
        files = sorted(SHOT_DIR.glob(f"{prefix}*.png"))
        sset = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == dtype), None)
        old = api("GET", f"/v1/appScreenshotSets/{sset['id']}/appScreenshots?limit=50")["data"] if sset else []
        print(f"{dtype}: {len(files)} files, {len(old)} existing screenshot(s) {[o['attributes'].get('fileName') for o in old]}")
        if DRY:
            continue
        if sset is None:
            sset = api("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": dtype},
                "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]
        for o in old:
            api("DELETE", f"/v1/appScreenshots/{o['id']}")
        rel = {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": sset["id"]}}}
        new = [with_retry(f"{dtype} {f.name}", lambda f=f: put_asset("/v1/appScreenshots", rel, f, "appScreenshots"), "/v1/appScreenshots")
               for f in files]
        new = [i for i in new if i]
        api("PATCH", f"/v1/appScreenshotSets/{sset['id']}/relationships/appScreenshots",
            {"data": [{"type": "appScreenshots", "id": i} for i in new]})
    return loc["id"]


# 3. Verify (read back)
def verify(loc_id):
    print("== verify (read back) ==")
    for pid, sid in SUBS.items():
        shot = (api("GET", f"/v1/subscriptions/{sid}/appStoreReviewScreenshot", ok404=True) or {}).get("data")
        st = state_of(shot) if shot else "MISSING"
        report.append(f"{pid} review screenshot: {shot['id'] if shot else '-'} {shot['attributes'].get('fileName') if shot else ''} {st}")
        if st != "COMPLETE":
            failures.append(f"{pid} review screenshot {st}")
    lid = LIFETIME[1]
    shot = (api("GET", f"/v2/inAppPurchases/{lid}/appStoreReviewScreenshot", ok404=True) or {}).get("data")
    st = state_of(shot) if shot else "MISSING"
    report.append(f"{LIFETIME[0]} review screenshot: {shot['id'] if shot else '-'} {shot['attributes'].get('fileName') if shot else ''} {st}")
    if st != "COMPLETE":
        failures.append(f"{LIFETIME[0]} review screenshot {st}")
    # product states can lag behind the asset; poll up to ~3 min
    paths = {pid: f"/v1/subscriptions/{sid}" for pid, sid in SUBS.items()} | {LIFETIME[0]: f"/v2/inAppPurchases/{LIFETIME[1]}"}
    states = {}
    for _ in range(36):
        states = {pid: api("GET", p)["data"]["attributes"].get("state") for pid, p in paths.items()}
        if all(s == "READY_TO_SUBMIT" for s in states.values()):
            break
        time.sleep(5)
    for pid, s in states.items():
        report.append(f"{pid} state: {s}")
        if s != "READY_TO_SUBMIT":
            failures.append(f"{pid} state {s}")
    if loc_id is None:
        return
    sets = api("GET", f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets?limit=50")["data"]
    for dtype, prefix in SETS.items():
        want = [f.name for f in sorted(SHOT_DIR.glob(f"{prefix}*.png"))]
        sset = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == dtype), None)
        items = api("GET", f"/v1/appScreenshotSets/{sset['id']}/appScreenshots?limit=50")["data"] if sset else []
        got = [i["attributes"].get("fileName") for i in items]
        for n, i in enumerate(items, 1):
            report.append(f"{dtype} #{n}: {i['attributes'].get('fileName')} {i['id']} {state_of(i)} "
                          f"{(i['attributes'].get('imageAsset') or {}).get('width')}x{(i['attributes'].get('imageAsset') or {}).get('height')}")
            if state_of(i) != "COMPLETE":
                failures.append(f"{dtype} {i['attributes'].get('fileName')} {state_of(i)}")
        ok = got == want
        report.append(f"{dtype}: count {len(got)} (want {len(want)}), order {'OK' if ok else 'MISMATCH ' + str(got)}")
        if not ok:
            failures.append(f"{dtype} count/order mismatch: {got}")


if __name__ == "__main__":
    review_shots()
    loc = store_shots()
    if DRY:
        print("dry run: no changes")
        sys.exit(0)
    verify(loc)
    print("\n=== verified states ===")
    print("\n".join(report))
    if failures:
        print("\nFAILURES:\n" + "\n".join(failures))
    with open(os.environ.get("GITHUB_STEP_SUMMARY", "/dev/null"), "a") as s:
        s.write("```\n" + "\n".join(report + (["", "FAILURES:"] + failures if failures else [])) + "\n```\n")
    sys.exit(1 if failures else 0)
