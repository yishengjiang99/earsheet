# AI Music Radar: ads launch to-do (X Ads + Reddit Ads)

An ordered checklist for Yisheng to run the first paid test himself. It depends on two PRs being merged and deployed:
- earsheet: the landing page, pixels and thanks page (`tools/music-radar-site`).
- finalcut: Stripe checkout, entitlements and the Conversions API.

Audiences and creatives come from `docs/research/commercialization.md` (PR #93).

**Budget numbers here are my assumptions, not data.** (business.x.com help pages block automated fetches, so the X Ads menu paths below come from X's help center as quoted by search results and from docs.x.com; check them against the live UI.) Ad-platform menu names change often. Each step links the official help page it was checked against on 2026-10-22, and those pages win if the UI differs.

Off switch for everything: set `ADS_TRACKING_ENABLED=0`. Use it in two places: the earsheet repo variable (pixels, then redeploy the site) and the finalcut server env (Conversions API, then restart).

---

## 0. Before any ad money (one time, about 1 hour)
- [ ] **Stripe dashboard (live mode)**, under Product catalog → Add product:
  - "AI Music Radar Pro" with two recurring prices: **$4.99 / month** and **$29.99 / year**.
  - "AI Music Radar Lifetime" with one **one-time** price: **$49.99**.
  - Copy the three `price_…` IDs. The 7-day trial is set by the server, so don't add a trial on the price.
- [ ] **Stripe → Developers → Webhooks**, on the existing grepawk.com endpoint (`https://grepawk.com/api/stripe-webhook`): also subscribe to `customer.subscription.updated` and `invoice.paid`. It should already have `checkout.session.completed` and `customer.subscription.deleted`.
- [ ] **finalcut server env** (`/root/finalcut/.env` or wherever finalcut.service reads it), then restart:
  ```
  MUSIC_STRIPE_PRICE_PRO_MONTHLY=price_…
  MUSIC_STRIPE_PRICE_PRO_YEARLY=price_…
  MUSIC_STRIPE_PRICE_LIFETIME=price_…
  MUSIC_SITE_URL=https://music.grepawk.com
  ADS_TRACKING_ENABLED=1
  ```
- [ ] Merge and deploy both PRs. Then smoke-test: on music.grepawk.com, click **Start free trial, yearly**. You should land on Stripe Checkout, and **Cancel** should bring you back to `/#pricing`. Do one real Lifetime purchase with your own card, and refund it in Stripe. Check that `/thanks` shows.
- [ ] Decide what a buyer gets **before** you spend on ads. The app isn't on the App Store, and nothing reads the new music entitlement yet. The page promises: "tied to your checkout email; we'll email you to unlock Pro the day the iPhone app launches." Either keep that promise, or run the first ads to the **free demo + waitlist** only (recommended).

## 1. X Ads account and billing
- [ ] Go to https://ads.x.com while signed in as the brand handle, and pick country, time zone (America/Los_Angeles) and currency (USD). The time zone can't be changed later.
- [ ] Add a payment method (card). The **Tools** menu, which holds Events Manager, only shows up once a card is on file. Help: https://business.x.com/en/help/account-setup/ads-account-setup and https://business.x.com/en/help/account-setup/payment-methods

## 2. X Pixel and events (paste the IDs into GitHub, not into code)
- [ ] Go to **Tools → Events Manager → Add event source → X Pixel**. Keep "Allow 1st-party cookies" on, then **Save event source**. Help: https://business.x.com/en/help/campaign-measurement-and-analytics/conversion-tracking-for-websites
- [ ] Click **View base code** and copy the short id inside `twq('config','XXXXX')`. That's the **Pixel ID**.
- [ ] **Add events**, three times, each with Setup method **Define event with code**:
  - Type **Purchase**, named "Music Purchase".
  - Type **Start trial**, named "Music Start Trial". If there's no Start trial type, use **Subscribe**.
  - Type **Lead**, named "Music Waitlist".

  Each event shows an id like `tw-XXXXX-YYYYY`. Copy all three.
- [ ] In GitHub → `yishengjiang99/earsheet` → Settings → Secrets and variables → Actions → **Variables**, add:
  ```
  ADS_TRACKING_ENABLED=1
  MUSIC_X_PIXEL_ID=XXXXX
  MUSIC_X_EVENT_ID_PURCHASE=tw-XXXXX-…
  MUSIC_X_EVENT_ID_START_TRIAL=tw-XXXXX-…
  MUSIC_X_EVENT_ID_LEAD=tw-XXXXX-…
  ```
  Then run the "Deploy music.grepawk.com" workflow. Check that `https://music.grepawk.com/ads-config.js` shows `"enabled":true` and your IDs.
- [ ] **X Conversions API (server)**. This needs X **Ads API access**: apply in the X Developer Console and wait for approval. Until then the pixel alone works, and the server simply doesn't send to X. Docs: https://docs.x.com/x-ads-api/measurement/web-conversions
  - Once approved, generate the app's consumer key and secret plus a user access token and secret for a handle with Ad Manager or Account Admin access on the ads account.
  - Put these in the **finalcut** env and restart:
    ```
    MUSIC_X_PIXEL_ID=XXXXX
    MUSIC_X_EVENT_ID_PURCHASE=tw-XXXXX-…
    MUSIC_X_EVENT_ID_START_TRIAL=tw-XXXXX-…
    X_ADS_CONSUMER_KEY=…  X_ADS_CONSUMER_SECRET=…
    X_ADS_ACCESS_TOKEN=…  X_ADS_ACCESS_TOKEN_SECRET=…
    ```

## 3. Reddit Ads account and billing
- [ ] Sign up at https://ads.reddit.com (Reddit for Business) and create the business and ad account, with time zone America/Los_Angeles and currency USD.
- [ ] Add a payment method under billing. Reddit doesn't review or serve ads without one. Help: https://business.reddithelp.com/articles/Knowledge/Set-up-a-Reddit-Ads-Campaign

## 4. Reddit Pixel and Conversions API token
- [ ] Go to **Events Manager**, install the Reddit Pixel, choose the manual/code option, and copy the **Pixel ID** (from `rdt('init','…')`). Help: https://business.reddithelp.com/s/article/Install-the-Reddit-Pixel-on-your-website
- [ ] Don't use the no-code Event Setup Tool for Purchase, Lead or StartTrial. `ads.js` already fires them with a dedupe id, and setting them up twice double-counts. Help: https://business.reddithelp.com/s/article/conversion-events-in-the-event-setup-tool
- [ ] Go to **Events Manager → Conversions API → Generate Access Token**, name it "music-grepawk", and copy it right away (you can't see it again). Help: https://business.reddithelp.com/s/article/conversion-access-token
- [ ] Add the earsheet repo variable `MUSIC_REDDIT_PIXEL_ID=…` and redeploy the site.
- [ ] Add to the finalcut env, then restart:
  ```
  MUSIC_REDDIT_PIXEL_ID=…
  REDDIT_CAPI_TOKEN=…
  ```
  Docs: https://ads-api.reddit.com/docs/v3/guides/programs/capi/direct-integration

## 5. Verify events (before launch)
- [ ] Open `https://music.grepawk.com/?utm_source=test&twclid=test123&rdt_cid=test456` in Chrome with ad blockers off and Global Privacy Control off.
  - With the **X Pixel Helper** extension you should see the pixel load.
  - With the **Reddit Pixel Helper** extension you should see `PageVisit`.
- [ ] Join the waitlist with a test email. You should come back to `/?waitlist=ok#waitlist`, and **Lead** fires on both pixels.
- [ ] Start a Pro trial with your own card. On `/thanks`, **StartTrial** fires (X "Start trial" event and Reddit Custom "StartTrial").
  - The finalcut logs should show no `[ads] … CAPI` warnings.
  - In Stripe → the session → Metadata you should see `product=music`, `event_id`, `utm_source=test`, `twclid`, `rdt_cid`.
  - Cancel the trial in Stripe.
- [ ] In X Events Manager and Reddit Events Manager, the events show as **active / received** within about an hour, and server events appear next to browser events without being doubled (they share `conversion_id`).
- [ ] With GPC turned on (for example Brave, or the DuckDuckGo extension), the pixels should **not** load. That's the privacy policy promise.

## 6. Campaign objective
- [ ] **X:** create a campaign with objective **Website traffic**, optimized for landing-page views, for the first test.
  - Switch to **Website conversions** (optimizing for Start trial or Waitlist) once about 20 or more conversions a week are coming in. That threshold is my assumption.
  - Destination: `https://music.grepawk.com/?utm_source=x&utm_medium=paid&utm_campaign=launch1&utm_content=<creative>`
  - Help: https://business.x.com/en/help/campaign-setup/campaign-objectives
- [ ] **Reddit:** create a campaign with objective **Conversions**, goal **Lead** (waitlist) to start, or **Traffic** if Lead has too little data.
  - Destination: `https://music.grepawk.com/?utm_source=reddit&utm_medium=paid&utm_campaign=launch1&utm_content=<creative>`
  - Help: https://business.reddithelp.com/s/article/Ad-campaign-objectives and https://business.reddithelp.com/s/article/Conversion-Goals

## 7. Audiences (from commercialization.md §5)
- [ ] **X:**
  - Location US. Language English.
  - Interests: Music, Musical instruments, Education.
  - Follower look-alikes: @musescore, @flowkey, @simplypiano, @Yousician.
  - Keywords: "sheet music", "transcribe", "piano cover", "learn by ear".
  - Turn Optimized/Expanded targeting **off** for the first test so the audience stays readable.
  - Help: https://business.x.com/en/help/campaign-setup/campaign-targeting
- [ ] **Reddit:**
  - Community targeting: r/piano, r/pianolearning, r/musictheory, r/WeAreTheMusicMakers, r/Guitar, r/learnmusic, r/composer, r/musescore, r/musicteachers.
  - Interest: Music.
  - Help: https://www.business.reddit.com/advertise/targeting/community-and-interest

## 8. Creatives (pick 3 per platform from commercialization.md §5)
- [ ] **X:**
  - #1 "Hum it, see it." Use a video: cut the first 6–10 s of `ai-music-radar-tiktok.mp4`.
  - #2 "That song stuck in your head?"
  - #4 the teacher angle.
- [ ] **Reddit:**
  - #6 the dev's native text post, "I built an on-device audio→sheet music app, roast my transcription".
  - #1 the video.
  - #2.
  - Lead with the free demo, not the price.
- [ ] Don't run #3 (price contrast) until you've rechecked competitor prices on the vendors' own sites. Don't run #5 (privacy) unless the ad says "app", since the website does use ad pixels.
- [ ] CTA: "Try the free demo" or "Learn more". Every ad URL gets its own `utm_content`.

## 9. Budget (ALL ASSUMPTIONS, set your own)
- [ ] About **$20/day per platform for 14 days** (about $300 each), split across 3 creatives. Use a campaign-level daily cap, plus a total cap of $300 on each platform so it can't overspend.
- [ ] Bidding: platform auto-bid. Don't set manual bids in week 1.

## 10. Launch
- [ ] Launch both on a weekday morning (PT), so day 1 gets a full day of data. Expect review delays of a few hours to about a day.
- [ ] Note the launch time and the starting counts in Stripe, the waitlist and the telemetry, so you can compare later.

## 11. What to watch
**Day 1 (is it working?)**
- [ ] Ads approved and spending. If X or Reddit shows nothing after 24 h, check review status and payment.
- [ ] Clicks reach the site: first-party `web_page_view` with `utm_source=x|reddit` (admin at music.grepawk.com/admin).
- [ ] The pixels report PageVisit / landing-page views. No conversion errors in Events Manager, and no `[ads]` warnings in the finalcut logs.

**Day 3 (kill obvious losers; thresholds are assumptions)**
- [ ] Pause any creative under **0.5% CTR after 2,000 impressions**.
- [ ] Landing → demo click rate (`web_demo_click` / `web_page_view`). Under about 15% means the page or the ad promise is off (assumption).
- [ ] Cost per waitlist lead and per demo start. Move budget to the best creative on each platform.

**Day 7 (is it worth continuing?)**
- [ ] Compare trials, purchases and waitlist sign-ups (Stripe + `music_waitlist`) with the platform-reported conversions, to see if they roughly match.
- [ ] Cost per paid user vs first-year value ($29.99 yearly, $49.99 lifetime). If CAC is above about $30 with no trend down, stop and fix the funnel (app launch, demo quality) before spending more (assumption).
- [ ] Keep the better platform for week 2, and switch it to the Conversions objective if it has enough events.
- [ ] To stop everything: pause the campaigns, then set `ADS_TRACKING_ENABLED=0` (site variable + redeploy, and finalcut env + restart).
