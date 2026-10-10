// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import StoreKit
import StoreKitTest
@testable import EarSheet

/// Paywall copy/pricing math (pure) + the Products.storekit configuration matching App Store Connect.
final class PaywallPricingTests: XCTestCase {
    typealias P = PaywallPricing
    let year = P.Period(value: 1, unit: .year)
    let month = P.Period(value: 1, unit: .month)
    let week = P.Period(value: 1, unit: .week)

    // MARK: - Monthly equivalent / savings (Decimal, no hardcoded USD or 50%)

    func testMonthlyEquivalentUsesDecimalDivision() {
        let m = P.monthlyEquivalent(price: Decimal(string: "29.99")!, period: year)!
        XCTAssertEqual(NSDecimalNumber(decimal: m).doubleValue, 29.99 / 12, accuracy: 1e-9)
        XCTAssertNil(P.monthlyEquivalent(price: 4.99, period: month), "monthly plan has no ≈/month line")
        XCTAssertNil(P.monthlyEquivalent(price: 1.99, period: week))
        let q = P.monthlyEquivalent(price: 12, period: P.Period(value: 3, unit: .month))!
        XCTAssertEqual(q, 4)
    }

    func testMonthlyEquivalentFormatsInProductCurrency() {
        let m = P.monthlyEquivalent(price: Decimal(string: "29.99")!, period: year)!
        let usd = m.formatted(Decimal.FormatStyle.Currency(code: "USD", locale: Locale(identifier: "en_US")))
        XCTAssertEqual(usd, "$2.50")
        let jpy = P.monthlyEquivalent(price: 4800, period: year)!
            .formatted(Decimal.FormatStyle.Currency(code: "JPY", locale: Locale(identifier: "ja_JP")))
        XCTAssertTrue(jpy.contains("400"), jpy)
        XCTAssertFalse(jpy.contains("$"), jpy)
    }

    func testSavingsPercentIsComputedAndRoundedDown() {
        // 29.99 vs 12 × 4.99 = 59.88 -> 49.9…% -> 49 (never overstated as 50%).
        XCTAssertEqual(P.savingsPercent(price: Decimal(string: "29.99")!, period: year, monthlyPrice: Decimal(string: "4.99")!), 49)
        XCTAssertEqual(P.savingsPercent(price: 60, period: year, monthlyPrice: 10), 50)
        XCTAssertEqual(P.savingsPercent(price: 4800, period: year, monthlyPrice: 800), 50)
        XCTAssertNil(P.savingsPercent(price: 120, period: year, monthlyPrice: 10), "no saving -> no badge")
        XCTAssertNil(P.savingsPercent(price: 130, period: year, monthlyPrice: 10))
        XCTAssertNil(P.savingsPercent(price: 4.99, period: month, monthlyPrice: 4.99))
        XCTAssertNil(P.savingsPercent(price: 10, period: year, monthlyPrice: 0))
    }

    // MARK: - Trial copy only when eligible and offered

    func testTrialRequiresEligibilityAndFreeTrialOffer() {
        XCTAssertEqual(P.eligibleTrial(isEligible: true, offerIsFreeTrial: true, offerPeriod: week), P.Trial(period: week))
        XCTAssertNil(P.eligibleTrial(isEligible: false, offerIsFreeTrial: true, offerPeriod: week))
        XCTAssertNil(P.eligibleTrial(isEligible: true, offerIsFreeTrial: false, offerPeriod: week))
        XCTAssertNil(P.eligibleTrial(isEligible: true, offerIsFreeTrial: true, offerPeriod: nil))
    }

    func testCTA() {
        let trial = P.Trial(period: week)
        XCTAssertEqual(P.ctaTitle(isSubscription: true, displayPrice: "$29.99", period: year, trial: trial),
                       "Try 7 days free, then $29.99/year")
        XCTAssertEqual(P.ctaTitle(isSubscription: true, displayPrice: "$29.99", period: year, trial: nil),
                       "Subscribe for $29.99/year")
        XCTAssertEqual(P.ctaTitle(isSubscription: true, displayPrice: "4,99 €", period: month, trial: nil),
                       "Subscribe for 4,99 €/month")
        XCTAssertEqual(P.ctaTitle(isSubscription: false, displayPrice: "$49.99", period: nil, trial: nil),
                       "Buy for $49.99")
        XCTAssertEqual(P.ctaTitle(isSubscription: true, displayPrice: "$9.99", period: month,
                                  trial: P.Trial(period: P.Period(value: 1, unit: .month))),
                       "Try 1 month free, then $9.99/month")
    }

    func testSubtitlesNeverMentionTrialWhenIneligible() {
        let ineligible = P.planSubtitle(isSubscription: true, period: year, monthlyEquivalentText: "$2.50", trial: nil)
        XCTAssertEqual(ineligible, "≈ $2.50/month, billed yearly")
        XCTAssertFalse(ineligible.contains("free"))
        XCTAssertEqual(P.planSubtitle(isSubscription: true, period: year, monthlyEquivalentText: "$2.50", trial: P.Trial(period: week)),
                       "≈ $2.50/month, billed yearly · 7 days free")
        XCTAssertEqual(P.planSubtitle(isSubscription: true, period: month, monthlyEquivalentText: nil, trial: nil),
                       "Billed monthly, cancel anytime")
        XCTAssertEqual(P.planSubtitle(isSubscription: false, period: nil, monthlyEquivalentText: nil, trial: nil),
                       "One payment, no renewal")
    }

    func testDisclosureHasAutoRenewTerms() {
        let s = P.disclosure(isSubscription: true, displayName: "Pro Yearly", displayPrice: "$29.99", period: year,
                             trial: P.Trial(period: week))
        XCTAssertTrue(s.hasPrefix("Pro Yearly: $29.99 per year after a 7-day free trial."), s)
        XCTAssertTrue(s.contains("renews automatically"))
        XCTAssertTrue(s.contains("24 hours"))
        XCTAssertTrue(s.contains("App Store account settings"))
        let noTrial = P.disclosure(isSubscription: true, displayName: "Pro Monthly", displayPrice: "$4.99", period: month, trial: nil)
        XCTAssertFalse(noTrial.contains("free trial"))
        XCTAssertTrue(noTrial.contains("at confirmation of purchase"))
        let life = P.disclosure(isSubscription: false, displayName: "Lifetime Pro", displayPrice: "$49.99", period: nil, trial: nil)
        XCTAssertTrue(life.contains("does not renew"))
    }

    @MainActor
    func testLegalLinks() {
        XCTAssertEqual(PaywallView.termsURL.absoluteString, "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
        XCTAssertEqual(PaywallView.privacyURL.host, "grepawk.com")
    }

    @MainActor
    func testPaywallOrdering() {
        XCTAssertLessThan(ProStore.paywallRank(ProStore.yearlyID), ProStore.paywallRank(ProStore.monthlyID))
        XCTAssertLessThan(ProStore.paywallRank(ProStore.monthlyID), ProStore.paywallRank(ProStore.lifetimeID))
        XCTAssertEqual(ProStore.paywallRank("other"), 99)
    }

    // MARK: - Products.storekit matches App Store Connect

    static var storekitURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Products.storekit")
    }

    func testStoreKitConfigurationMatchesASC() throws {
        let data = try Data(contentsOf: Self.storekitURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settings = try XCTUnwrap(json["settings"] as? [String: Any])
        XCTAssertEqual(settings["_applicationInternalID"] as? String, "6818838017")
        XCTAssertEqual(settings["_developerTeamID"] as? String, "83D36RPMUM")

        let products = try XCTUnwrap(json["products"] as? [[String: Any]])
        XCTAssertEqual(products.count, 1)
        let life = products[0]
        XCTAssertEqual(life["productID"] as? String, ProStore.lifetimeID)
        XCTAssertEqual(life["type"] as? String, "NonConsumable")
        XCTAssertEqual(life["displayPrice"] as? String, "49.99")
        XCTAssertEqual(life["familyShareable"] as? Bool, false)

        let groups = try XCTUnwrap(json["subscriptionGroups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["id"] as? String, "22437376")
        XCTAssertEqual(groups[0]["name"] as? String, "AI Music Radar Pro")
        let subs = try XCTUnwrap(groups[0]["subscriptions"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: subs.map { ($0["productID"] as? String ?? "", $0) })
        let expected: [(String, String, String, Int)] = [
            (ProStore.yearlyID, "29.99", "P1Y", 1),
            (ProStore.monthlyID, "4.99", "P1M", 2),
        ]
        for (id, price, period, level) in expected {
            let s = try XCTUnwrap(byID[id], id)
            XCTAssertEqual(s["type"] as? String, "RecurringSubscription")
            XCTAssertEqual(s["displayPrice"] as? String, price)
            XCTAssertEqual(s["recurringSubscriptionPeriod"] as? String, period)
            XCTAssertEqual(s["groupNumber"] as? Int, level)
            XCTAssertEqual(s["familyShareable"] as? Bool, false, "Family Sharing is off in ASC")
            XCTAssertEqual(s["subscriptionGroupID"] as? String, "22437376")
            let intro = try XCTUnwrap(s["introductoryOffer"] as? [String: Any])
            XCTAssertEqual(intro["paymentMode"] as? String, "free")
            XCTAssertEqual(intro["subscriptionPeriod"] as? String, "P1W")
            XCTAssertEqual(intro["numberOfPeriods"] as? Int, 1)
        }
        XCTAssertEqual(Set(byID.keys).union([life["productID"] as? String ?? ""]), Set(ProStore.productIDs))
    }

    func testSchemeUsesStoreKitConfigForDebugLaunchOnly() throws {
        let scheme = Self.storekitURL.deletingLastPathComponent()
            .appendingPathComponent("EarSheet.xcodeproj/xcshareddata/xcschemes/EarSheet.xcscheme")
        let xml = try String(contentsOf: scheme, encoding: .utf8)
        let launch = try XCTUnwrap(xml.range(of: "<LaunchAction"))
        let launchEnd = try XCTUnwrap(xml.range(of: "</LaunchAction>"))
        let launchBlock = xml[launch.lowerBound..<launchEnd.upperBound]
        XCTAssertTrue(launchBlock.contains("buildConfiguration = \"Debug\""))
        XCTAssertTrue(launchBlock.contains("identifier = \"../../Products.storekit\""))
        let archive = try XCTUnwrap(xml.range(of: "<ArchiveAction"))
        XCTAssertFalse(xml[archive.lowerBound...].contains("StoreKitConfigurationFileReference"))
    }

    // MARK: - Live StoreKit (local StoreKit Testing session from Products.storekit)

    @MainActor
    func testProductsLoadFromLocalStoreKitSession() async throws {
        let session: SKTestSession
        do {
            session = try SKTestSession(contentsOf: Self.storekitURL)
        } catch {
            throw XCTSkip("SKTestSession unavailable here: \(error)")
        }
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true

        let store = ProStore()
        await store.loadProducts(force: true)
        if store.products.isEmpty {
            throw XCTSkip("local StoreKit returned no products (\(store.productsError ?? "-"))")
        }
        XCTAssertEqual(store.products.map(\.id), [ProStore.yearlyID, ProStore.monthlyID, ProStore.lifetimeID])
        XCTAssertNil(store.productsError)

        let yearly = try XCTUnwrap(store.product(for: ProStore.yearlyID))
        let monthly = try XCTUnwrap(store.product(for: ProStore.monthlyID))
        XCTAssertEqual(yearly.price, Decimal(string: "29.99"))
        XCTAssertEqual(monthly.price, Decimal(string: "4.99"))
        let yearlySub = try XCTUnwrap(yearly.subscription)
        XCTAssertEqual(PaywallPricing.Period(yearlySub.subscriptionPeriod), year)
        // Fresh local StoreKit session: eligible, so trial copy appears; a 1-week free trial.
        XCTAssertEqual(store.eligibleTrial(for: yearly), P.Trial(period: week))
        let lifetime = try XCTUnwrap(store.product(for: ProStore.lifetimeID))
        XCTAssertNil(store.eligibleTrial(for: lifetime))
        let perMonth = try XCTUnwrap(P.monthlyEquivalent(price: yearly.price, period: year)).formatted(yearly.priceFormatStyle)
        XCTAssertTrue(perMonth.contains("2.50"), perMonth)
    }
}
