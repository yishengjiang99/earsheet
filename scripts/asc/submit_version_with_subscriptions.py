#!/usr/bin/env python3
"""AI Music Radar (com.ragnus.pnge, ASC app 6818838017): submit version VERSION_STRING (build BUILD_NUMBER)
for App Review in ONE reviewSubmission together with the first subscriptions AND the first non-consumable.

Apple: the first auto-renewable subscription (+ its group) and the first In-App Purchase of each type must
ride with an app version in the same submission; otherwise 409 FIRST_SUBSCRIPTION_MUST_BE_SUBMITTED_ON_VERSION.

Items: appStoreVersion + subscriptionGroupVersion + one subscriptionVersion per subscription
       + one inAppPurchaseVersion per non-consumable (inAppPurchasesV2, GET /v2/inAppPurchases/{id}/versions).
Adapted from yishengjiang99/photo-recipes scripts/asc/submit_version_with_subscriptions.py.

MODE:
  status      read-only (GET only): build, version + review detail, group/subscriptions/IAPs, open submissions
  wait_build  read-only: poll until build BUILD_NUMBER is VALID
  post_build  clear export compliance on BUILD_NUMBER and add it to every internal TestFlight group
  cancel      pull reviewSubmission CANCEL_SUBMISSION_ID from review once and wait until the version is editable
  submit      attach BUILD_NUMBER, update review notes/contact, build ONE reviewSubmission with every item, submit
Env: APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID, APP_STORE_CONNECT_API_KEY_P8,
     BUNDLE_ID, VERSION_STRING, BUILD_NUMBER, MODE, CANCEL_SUBMISSION_ID, REVIEW_NOTES_FILE
"""
from __future__ import annotations
import json, os, sys, time
import jwt, requests

BASE = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.ragnus.pnge").strip()
VERSION_STRING = os.environ.get("VERSION_STRING", "1.0").strip()
BUILD_NUMBER = os.environ.get("BUILD_NUMBER", "").strip()
MODE = os.environ.get("MODE", "status").strip()
GROUP_REF = "AI Music Radar Pro"
SUB_IDS = ["com.ragnus.pnge.pro.yearly", "com.ragnus.pnge.pro.monthly"]
IAP_IDS = ["com.ragnus.pnge.lifetime"]
DONE = {"WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED"}
DRAFT_STATES = ("PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "DEVELOPER_REJECTED", "REJECTED")
VERSION_EDITABLE = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
                    "READY_FOR_REVIEW", "INVALID_BINARY")
CONTACT = {"contactFirstName": "Yisheng", "contactLastName": "Jiang", "contactEmail": "yisheng.jiang@gmail.com",
           "contactPhone": "+1 669 251 7789", "demoAccountRequired": False}
WRITE_MODES = ("submit", "cancel", "post_build")


def token():
    now = int(time.time())
    p8 = os.environ["APP_STORE_CONNECT_API_KEY_P8"].replace("\\n", "\n").strip()
    return jwt.encode({"iss": os.environ["APP_STORE_CONNECT_ISSUER_ID"].strip(), "iat": now, "exp": now + 1100,
                       "aud": "appstoreconnect-v1"}, p8, algorithm="ES256",
                      headers={"kid": os.environ["APP_STORE_CONNECT_KEY_ID"].strip()})


def api(method, path, body=None):
    if MODE not in WRITE_MODES and method != "GET":
        raise SystemExit(f"read-only mode but tried {method} {path}")
    for attempt in range(5):
        r = requests.request(method, path if path.startswith("http") else BASE + path, json=body,
                             headers={"Authorization": "Bearer " + token()}, timeout=90)
        if r.status_code == 429 or (r.status_code >= 500 and method == "GET"):
            time.sleep(3 * 2 ** attempt)
            continue
        return r.status_code, (r.json() if r.text else {})
    return r.status_code, (r.json() if r.text else {})


def must(method, path, body=None):
    code, j = api(method, path, body)
    if code >= 300:
        raise SystemExit(f"{method} {path} -> {code}: {json.dumps(j)[:2000]}")
    return j


def find_build(app_id):
    if not BUILD_NUMBER:
        return None
    bs = must("GET", f"/v1/builds?filter[app]={app_id}&filter[version]={BUILD_NUMBER}"
                     f"&filter[preReleaseVersion.version]={VERSION_STRING}&limit=10")["data"]
    return next((b for b in bs if not b["attributes"].get("expired")), None)


def get_version(app_id):
    vs = must("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS"
                     f"&filter[versionString]={VERSION_STRING}")["data"]
    return vs[0] if vs else None


def get_group(app_id):
    groups = must("GET", f"/v1/apps/{app_id}/subscriptionGroups?limit=50")["data"]
    return next((g for g in groups if g["attributes"].get("referenceName") == GROUP_REF), groups[0] if groups else None)


def get_iaps(app_id):
    return {i["attributes"].get("productId"): i
            for i in must("GET", f"/v1/apps/{app_id}/inAppPurchasesV2?limit=200")["data"]}


def latest(versions):
    return max(versions, key=lambda v: v["attributes"].get("version") or 0) if versions else None


def iap_versions(iap_id):
    code, j = api("GET", f"/v2/inAppPurchases/{iap_id}/versions?limit=50")
    if code >= 300:
        print(f"  (GET /v2/inAppPurchases/{iap_id}/versions -> {code}: {json.dumps(j)[:400]})")
        return []
    return j.get("data") or []


def item_summary(it):
    return {k: (v.get("data") or {}).get("id") for k, v in (it.get("relationships") or {}).items()
            if isinstance(v, dict) and v.get("data")}


def status(app_id):
    print("\n===== STATUS =====")
    b = find_build(app_id)
    print("BUILD", BUILD_NUMBER, b and (b["id"], b["attributes"].get("processingState"),
          "usesNonExemptEncryption=", b["attributes"].get("usesNonExemptEncryption"), b["attributes"].get("uploadedDate")))
    if b:
        groups = must("GET", f"/v1/apps/{app_id}/betaGroups?limit=50")["data"]
        for g in groups:
            if not g["attributes"].get("isInternalGroup"):
                continue
            gb = must("GET", f"/v1/betaGroups/{g['id']}/builds?limit=200")["data"]
            ts = must("GET", f"/v1/betaGroups/{g['id']}/betaTesters?limit=200")["data"]
            print("INTERNAL GROUP", g["id"], g["attributes"].get("name"), "allBuilds=",
                  g["attributes"].get("hasAccessToAllBuilds"), "hasBuild=", any(x["id"] == b["id"] for x in gb),
                  "testers=", [t["attributes"].get("email") for t in ts])
    for v in must("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=5")["data"]:
        a = v["attributes"]
        vb = (must("GET", f"/v1/appStoreVersions/{v['id']}/build").get("data") or {})
        print("VERSION", v["id"], a.get("versionString"), a.get("appStoreState"), a.get("appVersionState"),
              "build=", (vb.get("attributes") or {}).get("version"), vb.get("id"))
        code, rd = api("GET", f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail")
        if code < 300 and rd.get("data"):
            ra = rd["data"]["attributes"]
            print("  REVIEW DETAIL", rd["data"]["id"], {k: ra.get(k) for k in CONTACT},
                  "\n  NOTES:", (ra.get("notes") or "").replace("\n", " | "))
    g = get_group(app_id)
    if g:
        gv = must("GET", f"/v1/subscriptionGroups/{g['id']}/versions?limit=10")["data"]
        print("GROUP", g["id"], g["attributes"].get("referenceName"), [(x["id"], x["attributes"]) for x in gv])
        for s in must("GET", f"/v1/subscriptionGroups/{g['id']}/subscriptions?limit=50")["data"]:
            a = s["attributes"]
            sv = must("GET", f"/v1/subscriptions/{s['id']}/versions?limit=10")["data"]
            print("SUB", s["id"], a.get("productId"), a.get("state"), "period=", a.get("subscriptionPeriod"),
                  "level=", a.get("groupLevel"), "familySharable=", a.get("familySharable"),
                  [(x["id"], x["attributes"]) for x in sv])
            code, io = api("GET", f"/v1/subscriptions/{s['id']}/introductoryOffers?limit=50")
            terr = {}
            for o in (io.get("data") or []) if code < 300 else []:
                oa = o["attributes"]
                terr.setdefault((oa.get("offerMode"), oa.get("duration"), oa.get("numberOfPeriods")), 0)
                terr[(oa.get("offerMode"), oa.get("duration"), oa.get("numberOfPeriods"))] += 1
            print("  INTRO OFFERS", code, terr)
            code, pr = api("GET", f"/v1/subscriptions/{s['id']}/prices?filter[territory]=USA&include=subscriptionPricePoint&limit=5")
            pts = [x["attributes"].get("customerPrice") for x in (pr.get("included") or []) if x["type"] == "subscriptionPricePoints"] if code < 300 else []
            print("  USA PRICE", code, pts)
    for pid, i in get_iaps(app_id).items():
        a = i["attributes"]
        print("IAP", i["id"], pid, a.get("inAppPurchaseType"), a.get("state"), "familySharable=", a.get("familySharable"),
              [(x["id"], x["attributes"]) for x in iap_versions(i["id"])])
        code, ps = api("GET", f"/v2/inAppPurchases/{i['id']}/iapPriceSchedule?include=manualPrices,baseTerritory")
        if code < 300:
            print("  PRICE SCHEDULE", [x["attributes"] for x in (ps.get("included") or []) if x["type"] == "inAppPurchasePrices"][:3])
    for rs in must("GET", f"/v1/apps/{app_id}/reviewSubmissions?filter[platform]=IOS&limit=20")["data"]:
        a = rs["attributes"]
        if a.get("state") == "COMPLETE":
            continue
        items = must("GET", f"/v1/reviewSubmissions/{rs['id']}/items?limit=50")["data"]
        print("REVIEW SUBMISSION", rs["id"], a.get("state"), "submitted=", a.get("submittedDate"), "items=", len(items))
        for it in items:
            print("  ITEM", it["id"], it["attributes"].get("state"), item_summary(it))


def add_item(rs_id, rel_name, rel_type, rel_id):
    code, j = api("POST", "/v1/reviewSubmissionItems", {"data": {
        "type": "reviewSubmissionItems",
        "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": rs_id}},
                          rel_name: {"data": {"type": rel_type, "id": rel_id}}}}})
    blob = json.dumps(j)
    ok = code < 300 or "ALREADY" in blob.upper() or "DUPLICATE" in blob.upper()
    print(f"ADD ITEM {rel_name} {rel_id} -> {code}", (j.get("data") or {}).get("id") if code < 300 else blob[:2000])
    return ok


def update_review_detail(version_id):
    notes_file = os.environ.get("REVIEW_NOTES_FILE", "docs/asc/review_notes.txt")
    notes = open(notes_file).read().strip()
    attrs = dict(CONTACT, notes=notes)
    code, rd = api("GET", f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail")
    if code < 300 and rd.get("data"):
        rid = rd["data"]["id"]
        must("PATCH", f"/v1/appStoreReviewDetails/{rid}", {"data": {"type": "appStoreReviewDetails", "id": rid,
                                                                       "attributes": attrs}})
        print("REVIEW DETAIL updated", rid)
    else:
        j = must("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
                 "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})
        print("REVIEW DETAIL created", j["data"]["id"])


def post_build(app_id):
    b = find_build(app_id)
    if not b or b["attributes"].get("processingState") != "VALID":
        raise SystemExit(f"build {BUILD_NUMBER} not VALID: {b and b['attributes']}")
    if b["attributes"].get("usesNonExemptEncryption") is not False:
        must("PATCH", f"/v1/builds/{b['id']}", {"data": {"type": "builds", "id": b["id"],
                                                         "attributes": {"usesNonExemptEncryption": False}}})
        print("EXPORT COMPLIANCE cleared (usesNonExemptEncryption=false)")
    else:
        print("EXPORT COMPLIANCE already cleared")
    for g in must("GET", f"/v1/apps/{app_id}/betaGroups?limit=50")["data"]:
        if not g["attributes"].get("isInternalGroup") or g["attributes"].get("hasAccessToAllBuilds"):
            continue
        code, j = api("POST", f"/v1/betaGroups/{g['id']}/relationships/builds", {"data": [{"type": "builds", "id": b["id"]}]})
        print("ASSIGN build to", g["attributes"].get("name"), code, "" if code < 300 else json.dumps(j)[:500])


def main():
    app_id = must("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"][0]["id"]
    print("APP", app_id, BUNDLE_ID, "version", VERSION_STRING, "build", BUILD_NUMBER, "mode", MODE)

    if MODE == "wait_build":
        for i in range(80):
            b = find_build(app_id)
            st = b and b["attributes"].get("processingState")
            print(f"build {BUILD_NUMBER} poll {i + 1}: {st}", flush=True)
            if st == "VALID":
                return
            if st in ("FAILED", "INVALID"):
                raise SystemExit(f"build {BUILD_NUMBER} is {st}")
            time.sleep(30)
        raise SystemExit(f"build {BUILD_NUMBER} not VALID after 40 min")

    if MODE == "status":
        status(app_id)
        return

    if MODE == "post_build":
        post_build(app_id)
        status(app_id)
        return

    if MODE == "cancel":
        rs_id = os.environ["CANCEL_SUBMISSION_ID"].strip()
        a = must("GET", f"/v1/reviewSubmissions/{rs_id}")["data"]["attributes"]
        print("SUBMISSION", rs_id, a.get("state"))
        if a.get("state") not in ("WAITING_FOR_REVIEW", "UNRESOLVED_ISSUES", "CANCELING"):
            raise SystemExit(f"submission {rs_id} is {a.get('state')}; not cancelling")
        b = find_build(app_id)
        if not b or b["attributes"].get("processingState") != "VALID":
            raise SystemExit(f"replacement build {BUILD_NUMBER} not VALID yet; not pulling the review")
        if a.get("state") != "CANCELING":
            j = must("PATCH", f"/v1/reviewSubmissions/{rs_id}", {"data": {"type": "reviewSubmissions", "id": rs_id,
                                                                            "attributes": {"canceled": True}}})
            print("CANCEL requested ->", j["data"]["attributes"].get("state"))
        for i in range(60):
            st = must("GET", f"/v1/reviewSubmissions/{rs_id}")["data"]["attributes"].get("state")
            vs = get_version(app_id)["attributes"].get("appStoreState")
            print(f"poll {i + 1}: submission={st} version {VERSION_STRING}={vs}", flush=True)
            if st == "COMPLETE" and vs in ("DEVELOPER_REJECTED", "PREPARE_FOR_SUBMISSION"):
                break
            time.sleep(15)
        status(app_id)
        return

    if MODE != "submit":
        raise SystemExit(f"unknown MODE {MODE}")

    # ---- submit ----
    for rs in must("GET", f"/v1/apps/{app_id}/reviewSubmissions?filter[platform]=IOS&limit=50")["data"]:
        if rs["attributes"].get("state") in ("WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES", "CANCELING"):
            raise SystemExit(f"reviewSubmission {rs['id']} is {rs['attributes'].get('state')}; refusing to submit again")
    build = find_build(app_id)
    if not build or build["attributes"].get("processingState") != "VALID":
        raise SystemExit(f"build {BUILD_NUMBER} not VALID: {build and build['attributes']}")
    if build["attributes"].get("usesNonExemptEncryption") is not False:
        raise SystemExit("export compliance not cleared on build (run mode=post_build)")
    ver = get_version(app_id)
    vstate = ver["attributes"].get("appStoreState")
    if vstate not in VERSION_EDITABLE:
        raise SystemExit(f"version state {vstate} not submittable")
    vb = (must("GET", f"/v1/appStoreVersions/{ver['id']}/build").get("data") or {})
    if vb.get("id") != build["id"]:
        must("PATCH", f"/v1/appStoreVersions/{ver['id']}/relationships/build", {"data": {"type": "builds", "id": build["id"]}})
        vb = (must("GET", f"/v1/appStoreVersions/{ver['id']}/build").get("data") or {})
    print("VERSION", ver["id"], vstate, "attached build", vb.get("id"), (vb.get("attributes") or {}).get("version"))
    if vb.get("id") != build["id"]:
        raise SystemExit(f"could not attach build {BUILD_NUMBER} to version {VERSION_STRING}")
    update_review_detail(ver["id"])

    group = get_group(app_id) or sys.exit("no subscription group")
    subs = {s["attributes"]["productId"]: s for s in must("GET", f"/v1/subscriptionGroups/{group['id']}/subscriptions?limit=50")["data"]}
    sub_versions = []
    for pid in SUB_IDS:
        s = subs.get(pid) or sys.exit(f"MISSING {pid}")
        state = s["attributes"].get("state")
        print("SUB", pid, s["id"], state)
        if state in DONE:
            continue
        if state != "READY_TO_SUBMIT":
            raise SystemExit(f"NOT READY {pid}: {state}")
        sv = latest(must("GET", f"/v1/subscriptions/{s['id']}/versions?limit=50")["data"])
        print("  subscriptionVersion", sv and (sv["id"], sv["attributes"]))
        if not sv or sv["attributes"].get("state") not in DRAFT_STATES:
            raise SystemExit(f"no submittable subscriptionVersion for {pid}")
        sub_versions.append((pid, sv))
    gv = latest(must("GET", f"/v1/subscriptionGroups/{group['id']}/versions?limit=50")["data"])
    print("GROUP VERSION", gv and (gv["id"], gv["attributes"]))

    iaps = get_iaps(app_id)
    iap_vs = []
    for pid in IAP_IDS:
        i = iaps.get(pid) or sys.exit(f"MISSING IAP {pid}")
        state = i["attributes"].get("state")
        print("IAP", pid, i["id"], state)
        if state in DONE:
            continue
        if state != "READY_TO_SUBMIT":
            raise SystemExit(f"NOT READY {pid}: {state}")
        iv = latest(iap_versions(i["id"]))
        print("  inAppPurchaseVersion", iv and (iv["id"], iv["attributes"]))
        if not iv or iv["attributes"].get("state") not in DRAFT_STATES:
            raise SystemExit(f"no submittable inAppPurchaseVersion for {pid}")
        iap_vs.append((pid, iv))

    rss = must("GET", f"/v1/apps/{app_id}/reviewSubmissions?filter[platform]=IOS&limit=50")["data"]
    draft = None
    for r in rss:
        if r["attributes"].get("state") == "READY_FOR_REVIEW":
            n = len(must("GET", f"/v1/reviewSubmissions/{r['id']}/items?limit=50")["data"])
            print("READY_FOR_REVIEW submission", r["id"], "items=", n)
            if draft is None and n == 0:
                draft = r
    if draft:
        print("REUSE empty reviewSubmission", draft["id"])
    else:
        draft = must("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"},
                     "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]
        print("CREATED reviewSubmission", draft["id"])
    rs_id = draft["id"]

    ok = add_item(rs_id, "appStoreVersion", "appStoreVersions", ver["id"])
    if gv and gv["attributes"].get("state") in DRAFT_STATES:
        ok = add_item(rs_id, "subscriptionGroupVersion", "subscriptionGroupVersions", gv["id"]) and ok
    for pid, sv in sub_versions:
        ok = add_item(rs_id, "subscriptionVersion", "subscriptionVersions", sv["id"]) and ok
    for pid, iv in iap_vs:
        ok = add_item(rs_id, "inAppPurchaseVersion", "inAppPurchaseVersions", iv["id"]) and ok
    items = must("GET", f"/v1/reviewSubmissions/{rs_id}/items?limit=50")["data"]
    for it in items:
        print("ITEM", it["id"], it["attributes"].get("state"), item_summary(it))
    if not ok:
        raise SystemExit(f"could not add every item to reviewSubmission {rs_id}; NOT submitted")

    j = must("PATCH", f"/v1/reviewSubmissions/{rs_id}", {"data": {"type": "reviewSubmissions", "id": rs_id,
                                                                    "attributes": {"submitted": True}}})
    a = j["data"]["attributes"]
    print("SUBMIT_OK submission_id=", rs_id, "state=", a.get("state"), "submittedDate=", a.get("submittedDate"))
    time.sleep(10)
    status(app_id)


if __name__ == "__main__":
    main()
