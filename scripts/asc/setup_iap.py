#!/usr/bin/env python3
"""Create-only, idempotent App Store Connect setup for AI Music Radar IAP (ASC app 6818838017).

  1. App Store Server Notifications V2 URLs (production + sandbox) -> grepawk.com/music-radar/api/iap/notifications
  2. Subscription group "AI Music Radar Pro" (+ en-US localization)
  3. Auto-renewable subscriptions com.ragnus.pnge.pro.yearly ($29.99, level 1) and .pro.monthly ($4.99, level 2):
     en-US localization, USA price + Apple-equalized prices in every other territory, availability, 7-day free trial
  4. Non-consumable com.ragnus.pnge.lifetime ($49.99): en-US localization, price schedule (USA base), availability
Never deletes or edits existing prices. Env: APP_STORE_CONNECT_KEY_ID / _ISSUER_ID / _API_KEY_P8, DRY_RUN=1 to only read.
"""
import json, os, sys, time, urllib.error, urllib.request
import jwt

APP = os.environ.get("ASC_APP_ID", "6818838017")
WEBHOOK = os.environ.get("ASSN_URL", "https://grepawk.com/music-radar/api/iap/notifications")
DRY = os.environ.get("DRY_RUN") == "1"
GROUP = "AI Music Radar Pro"
SUBS = [
    {"productId": "com.ragnus.pnge.pro.yearly", "name": "Pro Yearly", "period": "ONE_YEAR", "level": 1, "usd": "29.99",
     "desc": "All Pro features, billed yearly."},
    {"productId": "com.ragnus.pnge.pro.monthly", "name": "Pro Monthly", "period": "ONE_MONTH", "level": 2, "usd": "4.99",
     "desc": "All Pro features, billed monthly."},
]
LIFETIME = {"productId": "com.ragnus.pnge.lifetime", "name": "Lifetime Pro", "usd": "49.99", "desc": "All Pro features forever, one purchase."}
REVIEW_NOTE = "Unlocks Pro in AI Music Radar (unlimited take length, MIDI/MusicXML/PDF export). The free tier keeps the live view."

p8 = os.environ["APP_STORE_CONNECT_API_KEY_P8"].replace("\\n", "\n").strip()
_tok = {"t": None, "at": 0}
def tok():
    if time.time() - _tok["at"] > 900:
        now = int(time.time())
        _tok["t"] = jwt.encode({"iss": os.environ["APP_STORE_CONNECT_ISSUER_ID"].strip(), "iat": now, "exp": now + 1150, "aud": "appstoreconnect-v1"},
                               p8, algorithm="ES256", headers={"kid": os.environ["APP_STORE_CONNECT_KEY_ID"].strip()})
        _tok["at"] = time.time()
    return _tok["t"]

class ApiError(Exception):
    pass

def api(method, path, body=None, ok404=False):
    if DRY and method != "GET":
        print("  DRY", method, path)
        return {"data": {"id": "dry", "attributes": {}}}
    url = path if path.startswith("http") else "https://api.appstoreconnect.apple.com" + path
    for attempt in range(5):
        req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                     headers={"Authorization": "Bearer " + tok(), "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                raw = r.read().decode()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            txt = e.read().decode()
            if e.code == 404 and ok404:
                return None
            if e.code == 429 or e.code >= 500:
                time.sleep(2 ** attempt * 3)
                continue
            raise ApiError(f"{method} {path} -> {e.code}: {txt[:1500]}")
    raise ApiError(f"{method} {path}: retries exhausted")

def all_pages(path):
    out = []
    while path:
        d = api("GET", path)
        out += d.get("data", [])
        path = d.get("links", {}).get("next")
    return out

summary, problems = [], []
def step(label, fn):
    try:
        r = fn()
        summary.append(f"OK   {label}" + (f": {r}" if r else ""))
    except ApiError as e:
        problems.append(f"FAIL {label}: {e}")
        print("FAIL", label, e, flush=True)

# 1. ASSN v2 URLs
def assn():
    a = api("GET", f"/v1/apps/{APP}")["data"]["attributes"]
    print("app", a.get("name"), a.get("bundleId"), "current ASSN:", a.get("subscriptionStatusUrl"), a.get("subscriptionStatusUrlForSandbox"))
    want = {"subscriptionStatusUrl": WEBHOOK, "subscriptionStatusUrlVersion": "V2",
            "subscriptionStatusUrlForSandbox": WEBHOOK, "subscriptionStatusUrlVersionForSandbox": "V2"}
    if all(a.get(k) == v for k, v in want.items()):
        return "already set"
    api("PATCH", f"/v1/apps/{APP}", {"data": {"type": "apps", "id": APP, "attributes": want}})
    return f"set to {WEBHOOK} (V2, production + sandbox)"
step("App Store Server Notifications V2 URLs", assn)

territories = [t["id"] for t in all_pages("/v1/territories?limit=200")]
print("territories:", len(territories))

# 2. Subscription group
group = next((g for g in all_pages(f"/v1/apps/{APP}/subscriptionGroups?limit=50") if g["attributes"].get("referenceName") == GROUP), None)
if not group:
    group = api("POST", "/v1/subscriptionGroups", {"data": {"type": "subscriptionGroups", "attributes": {"referenceName": GROUP},
             "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
    summary.append(f"OK   created subscription group {GROUP} ({group['id']})")
else:
    summary.append(f"OK   subscription group exists ({group['id']})")
gid = group["id"]
def group_loc():
    locs = api("GET", f"/v1/subscriptionGroups/{gid}/subscriptionGroupLocalizations") if gid != "dry" else {"data": []}
    if any(l["attributes"]["locale"] == "en-US" for l in locs.get("data", [])):
        return "exists"
    api("POST", "/v1/subscriptionGroupLocalizations", {"data": {"type": "subscriptionGroupLocalizations",
        "attributes": {"name": GROUP, "locale": "en-US"}, "relationships": {"subscriptionGroup": {"data": {"type": "subscriptionGroups", "id": gid}}}}})
    return "created"
step("group en-US localization", group_loc)

def find_point(points, usd):
    for p in points:
        if p["attributes"].get("customerPrice") in (usd, usd.rstrip("0")):
            return p
    raise ApiError(f"no USA price point at ${usd}")

# 3. Subscriptions
existing = {s["attributes"]["productId"]: s for s in (all_pages(f"/v1/subscriptionGroups/{gid}/subscriptions?limit=50") if gid != "dry" else [])}
for spec in SUBS:
    sub = existing.get(spec["productId"])
    if not sub:
        try:
            sub = api("POST", "/v1/subscriptions", {"data": {"type": "subscriptions", "attributes": {
                "name": spec["name"], "productId": spec["productId"], "subscriptionPeriod": spec["period"], "groupLevel": spec["level"],
                "familySharable": False, "reviewNote": REVIEW_NOTE},
                "relationships": {"group": {"data": {"type": "subscriptionGroups", "id": gid}}}}})["data"]
            summary.append(f"OK   created subscription {spec['productId']} ({sub['id']})")
        except ApiError as e:
            problems.append(f"FAIL create {spec['productId']}: {e}")
            continue
    else:
        summary.append(f"OK   subscription exists {spec['productId']} ({sub['id']}) state={sub['attributes'].get('state')}")
    sid = sub["id"]
    if sid == "dry":
        continue

    def sub_loc():
        locs = api("GET", f"/v1/subscriptions/{sid}/subscriptionLocalizations")
        if any(l["attributes"]["locale"] == "en-US" for l in locs.get("data", [])):
            return "exists"
        api("POST", "/v1/subscriptionLocalizations", {"data": {"type": "subscriptionLocalizations",
            "attributes": {"name": spec["name"], "description": spec["desc"], "locale": "en-US"},
            "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sid}}}}})
        return "created"
    step(f"{spec['productId']} en-US localization", sub_loc)

    def sub_prices():
        have = {p["relationships"]["territory"]["data"]["id"] for p in all_pages(f"/v1/subscriptions/{sid}/prices?include=territory&limit=200")
                if p.get("relationships", {}).get("territory", {}).get("data")}
        usa = find_point(all_pages(f"/v1/subscriptions/{sid}/pricePoints?filter[territory]=USA&limit=200"), spec["usd"])
        points = [usa] + all_pages(f"/v1/subscriptionPricePoints/{usa['id']}/equalizations?limit=200&include=territory")
        made = 0
        for pt in points:
            terr = pt.get("relationships", {}).get("territory", {}).get("data", {}).get("id") or "USA"
            if terr in have:
                continue
            api("POST", "/v1/subscriptionPrices", {"data": {"type": "subscriptionPrices", "attributes": {"preserveCurrentPrice": False},
                "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sid}},
                                  "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": pt["id"]}}}}})
            made += 1
        return f"USA ${spec['usd']}; {made} territory prices created, {len(have)} already set"

    def sub_avail():
        if api("GET", f"/v1/subscriptions/{sid}/subscriptionAvailability", ok404=True):
            return "exists"
        api("POST", "/v1/subscriptionAvailabilities", {"data": {"type": "subscriptionAvailabilities", "attributes": {"availableInNewTerritories": True},
            "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sid}},
                              "availableTerritories": {"data": [{"type": "territories", "id": t} for t in territories]}}}})
        return f"{len(territories)} territories"
    step(f"{spec['productId']} availability", sub_avail)
    # prices must come after availability (ASC rejects prices for territories the subscription is not available in)
    step(f"{spec['productId']} prices", sub_prices)

    def trial():
        have = {o["relationships"]["territory"]["data"]["id"] for o in all_pages(f"/v1/subscriptions/{sid}/introductoryOffers?include=territory&limit=200")
                if o.get("relationships", {}).get("territory", {}).get("data")}
        made = 0
        for t in territories:
            if t in have:
                continue
            api("POST", "/v1/subscriptionIntroductoryOffers", {"data": {"type": "subscriptionIntroductoryOffers",
                "attributes": {"duration": "ONE_WEEK", "offerMode": "FREE_TRIAL", "numberOfPeriods": 1},
                "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sid}},
                                  "territory": {"data": {"type": "territories", "id": t}}}}})
            made += 1
        return f"7-day free trial: {made} created, {len(have)} already set"
    step(f"{spec['productId']} intro offer", trial)

# 4. Lifetime non-consumable
iaps = {i["attributes"].get("productId"): i for i in all_pages(f"/v1/apps/{APP}/inAppPurchasesV2?limit=200")}
life = iaps.get(LIFETIME["productId"])
if not life:
    try:
        life = api("POST", "/v2/inAppPurchases", {"data": {"type": "inAppPurchases", "attributes": {
            "name": LIFETIME["name"], "productId": LIFETIME["productId"], "inAppPurchaseType": "NON_CONSUMABLE",
            "familySharable": False, "reviewNote": REVIEW_NOTE},
            "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
        summary.append(f"OK   created non-consumable {LIFETIME['productId']} ({life['id']})")
    except ApiError as e:
        problems.append(f"FAIL create {LIFETIME['productId']}: {e}")
else:
    summary.append(f"OK   non-consumable exists {LIFETIME['productId']} ({life['id']}) state={life['attributes'].get('state')}")
if life and life["id"] != "dry":
    lid = life["id"]
    def life_loc():
        locs = api("GET", f"/v2/inAppPurchases/{lid}/inAppPurchaseLocalizations")
        if any(l["attributes"]["locale"] == "en-US" for l in locs.get("data", [])):
            return "exists"
        api("POST", "/v1/inAppPurchaseLocalizations", {"data": {"type": "inAppPurchaseLocalizations",
            "attributes": {"name": LIFETIME["name"], "description": LIFETIME["desc"], "locale": "en-US"},
            "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": lid}}}}})
        return "created"
    step("lifetime en-US localization", life_loc)
    def life_price():
        if api("GET", f"/v2/inAppPurchases/{lid}/iapPriceSchedule", ok404=True):
            return "schedule exists"
        usa = find_point(all_pages(f"/v2/inAppPurchases/{lid}/pricePoints?filter[territory]=USA&limit=200"), LIFETIME["usd"])
        api("POST", "/v1/inAppPurchasePriceSchedules", {"data": {"type": "inAppPurchasePriceSchedules",
            "relationships": {"inAppPurchase": {"data": {"type": "inAppPurchases", "id": lid}},
                              "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                              "manualPrices": {"data": [{"type": "inAppPurchasePrices", "id": "${p1}"}]}}},
            "included": [{"type": "inAppPurchasePrices", "id": "${p1}", "attributes": {"startDate": None},
                          "relationships": {"inAppPurchasePricePoint": {"data": {"type": "inAppPurchasePricePoints", "id": usa["id"]}}}}]})
        return f"USA ${LIFETIME['usd']} base (other territories auto-equalized)"
    step("lifetime price schedule", life_price)
    def life_avail():
        if api("GET", f"/v2/inAppPurchases/{lid}/inAppPurchaseAvailability", ok404=True):
            return "exists"
        api("POST", "/v1/inAppPurchaseAvailabilities", {"data": {"type": "inAppPurchaseAvailabilities", "attributes": {"availableInNewTerritories": True},
            "relationships": {"inAppPurchase": {"data": {"type": "inAppPurchases", "id": lid}},
                              "availableTerritories": {"data": [{"type": "territories", "id": t} for t in territories]}}}})
        return f"{len(territories)} territories"
    step("lifetime availability", life_avail)

print("\n=== summary ===")
for s in summary + problems:
    print(s)
print("\nStill manual: review screenshot per product (required before submitting with an app version).")
sys.exit(1 if problems else 0)
