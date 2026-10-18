# Traceability: earsheet audit round 2 (issues #7-#45)

Last updated: 2026-10-17 19:50 PT (status-check routine). main = 9ecaad1 (PR #89). All 39 audit issues closed and code-verified; all fix PRs squash-merged (#52 closed, its content landed in #54). No open PRs. One follow-up issue open: #86 (StoreKit purchase hangs in sim CI).

ios-sim on main: run 39090468266 (9ecaad1, 19:32-19:40 PT) is GREEN: xcodebuild "** TEST SUCCEEDED **", 159 tests, 0 failures, 0 skips, allowlist guard passed, package tests passed. This is a real test run (about 8 minutes, every test case logged). History: 39087981502 (2d59db8) failed with 6 tests (StoreKit hangs #9 #13 #15; asserts #18 #21 #37); #87 fixed the three asserts and bounded the hangs; 39089142384 (526a97f) failed to compile (TestDeadline.swift missing StoreKit import); #88 bought via SKTestSession; 39089641691 (f51cc50) failed only the 3 StoreKit tests (SKInternalErrorDomain Code=3); #89 added an injectable entitlement source to ProStore (nil in production) and the StoreKit tests now use a fake source, so CI no longer exercises a real Product.purchase. Green-run verdict comments posted on #9 #13 #15 #18 #21 #37 #86 at 19:48 PT.

TestFlight: iOS TestFlight run 39090979311 on 9ecaad1 started 19:41 PT, in progress at 19:50 PT. Previous TestFlight run 2026-10-09 on ee7cc70 (ASC build #20; App Store version 1.0 WAITING_FOR_REVIEW on that build).

Allowlist: PR #85 added a workflow step that checks every XCTestCase class is in the -only-testing allowlist; it passed on 9ecaad1.

| Stream | Step | Issue | PR | Issue state | Verdict |
|---|---|---|---|---|---|
| A | P7.4 | #9 | #48 | closed | merged; code-verified on main (EntitlementManagerTests.testExpiredSubscriptionBlocksAfterRefresh); passed in green sim 39090468266 (failed earlier in 39087981502; fixed by #87/#89) |
| A | P4.2 | #28 | #54 (content of #52) | closed | merged; code-verified on main (PurchaseFlowTests.testPurchaseErrorCopyHasNoRawErrorText); passed in green sim 39090468266 |
| A | P6.4 | #16 | #54 | closed | merged; code-verified on main (RestoreFlowTests.testSyncCancelledIsSilent); passed in green sim 39090468266 |
| A | P6.2 | #15 | #56 | closed | merged; code-verified on main (RestoreFlowTests.testRestoreResults); passed in green sim 39090468266 (failed earlier in 39087981502; fixed by #87/#89) |
| A | P10.2 | #29 | #58 | closed | merged; code-verified on main (TelemetryPrivacyTests.testCancelAndPendingAreNotFailures, testTriggerPropertyAllowedAndPIIKeysStillDropped); passed in green sim 39090468266 |
| A | P5.3 | #13 | #60 | closed | merged; code-verified on main (PurchaseFlowTests.testApprovalOfPendingPurchaseSetsPro); passed in green sim 39090468266 (failed earlier in 39087981502; fixed by #87/#89) |
| A | P2.8 | #14 | #63 | closed | merged; code-verified on main (SettingsTests.testGoProRowRoutesByEntitlement); passed in green sim 39090468266 |
| A | F12.6 | #25 | #65 | closed | merged; code-verified on main (SettingsTests.testMeasureFloorDeniedDoesNotWriteFloor); passed in green sim 39090468266 |
| B | F9.4 | #7 | #46 | closed | merged; code-verified on main (QuotaGateTests.testAudioImportAtLimitIsHeldNotSaved); passed in green sim 39090468266 |
| B | P1.5 | #8 | #49 | closed | merged; code-verified on main (QuotaGateTests.testFreeImportSamplesCappedAt30s, testProImportCappedAt60s, testPaywallImportCopyMatchesPolicy); passed in green sim 39090468266 |
| B | F9.6 | #12 | #53 | closed | merged; code-verified on main (ListeningFlowTests.testImportErrorMessages); passed in green sim 39090468266 |
| B | F9.2 | #22 | #55 | closed | merged; code-verified on main (ListeningFlowTests.testImportCoordinatorStatesAndEmptyAudioNotice); passed in green sim 39090468266 |
| B | F9.5 | #23 | #61 | closed | merged; code-verified on main (QuotaGateTests.testHeldImportIsVisibleAndNotReplacedSilently); passed in green sim 39090468266 |
| B | F9.8 | #30 | #64 | closed | merged; code-verified on main (LibraryStorageTests.testImportRemovesTemporaryCopy); passed in green sim 39090468266 |
| B | F3.3 | #17 | #66 | closed | merged; code-verified on main (ListeningFlowTests.testDeniedPermissionPhaseIsTyped); passed in green sim 39090468266 |
| B | F4.3 | #18 | #67 | closed | merged; code-verified on main (ListeningFlowTests.testPumpFailureStopsRecorder); passed in green sim 39090468266 (failed earlier in 39087981502; fixed by #87/#89) |
| B | F4.7 | #19 | #68 | closed | merged; code-verified on main (ListeningFlowTests.testCancelDiscardsWithoutTake); passed in green sim 39090468266 |
| B | F5.6 | #10 | #69 | closed | merged; code-verified on main (ListeningFlowTests.testDiscardPendingRemovesAudioAndClearsHold); passed in green sim 39090468266 |
| B | F7.1 | #21 | #70 | closed | merged; code-verified on main (LibraryStorageTests.testCorruptFileIsPreservedAndNotOverwritten, testPartiallyInvalidArrayKeepsValidTakes, testWriteFailurePostsNotice); passed in green sim 39090468266 (failed earlier in 39087981502; fixed by #87/#89) |
| B | F7.3 | #20 | #71 | closed | merged; code-verified on main (LibraryStorageTests.testSweepRemovesUnreferencedWavsKeepsReferenced); passed in green sim 39090468266 |
| B | F2.5 | #35 | #72 | closed | merged; code-verified on main (LibraryStorageTests.testDefaultTitleIsUniqueAfterDelete); passed in green sim 39090468266 |
| B | F4.6 | #26 | #73 | closed | merged; code-verified on main (ListeningFlowTests.testBackgroundDuringListeningFinalizesTake); passed in green sim 39090468266 |
| B | F4.4 | #33 | #74 | closed | merged; code-verified on main (ListeningFlowTests.testLimitNoticeIsDeliveredToPresenter); passed in green sim 39090468266 |
| B | P1.8 | #36 | #75 | closed | merged; code-verified on main (PaywallTriggersTests.testPaywallDismissalCountsOnlyWhenAutomatic, testUserInitiatedDecisionsDoNotCount (renamed from testUserInitiatedDismissDoesNotCount by P1.9)); passed in green sim 39090468266 |
| B | F10.7 | #32 | #76 | closed | merged; code-verified on main (DebugExportRemovalTests.testNoClipboardWritesInExportActions; no UIPasteboard in Sources); passed in green sim 39090468266 |
| C | P10.4 | #11 | #47 | closed | merged; code-verified on main (PrivacyManifestTests.testPrivacyManifestPresentAndDeclaresUserDefaults); passed in green sim 39090468266 |
| C | F10.3 | #24 | #50 | closed | merged; code-verified on main (ExportFlowTests.testSecondExportIgnoredWhilePreparing); passed in green sim 39090468266 |
| C | F10.6 | #31 | #50 | closed | merged; code-verified on main (ExportFlowTests.testBaseNameKeepsUnicodeAndFallsBack); passed in green sim 39090468266 |
| C | P11.1 | #27 | #57 | closed | merged; code-verified on main (ReviewNotesLintTests.testReviewNotesMentionTopLeftGearSamplesAndMicrophone); passed in green sim 39090468266 |
| C | P11.2 | #34 | #59 | closed | merged; code-verified on main (docs only: subtitle/description/promo no longer claim a live score (docs/explainer/index.html still says "writes sheet music live"; outside issue scope)); no sim test (docs only) |
| C | F1.5 | #38 | #51 | closed | merged; code-verified on main (OnboardingTests.testOnboardingCopyDoesNotClaimNothingLeavesPhone); passed in green sim 39090468266 |
| C | F13.1 | #37 | #62 | closed | merged; code-verified on main (UserFacingErrorTests.testUserFacingErrorCopyHasNoTypeNames); passed in green sim 39090468266 (failed earlier in 39087981502; fixed by #87/#89) |
| D | P1.9 | #39 | #77 (closed by #83) | closed | merged; code-verified on main (UpgradePromptPolicyTests (15 tests: Pro, recording, first take, in-flight, caps, rank-4)); passed in green sim 39090468266 |
| D | P1.11 | #40 | #78 | closed | merged; code-verified on main (ImportLimitPromptTests.testLongFreeImportPromptsAndOthersGoStraightThrough); passed in green sim 39090468266 |
| D | P2.1 | #41 | #79 | closed | merged; code-verified on main (ExportInterstitialTests.testFirstShareShowsOnceForARealTake, testLockedRowTapsAlwaysOpenAndNeverCount); passed in green sim 39090468266 |
| D | P1.12 | #42 | #80 | closed | merged; code-verified on main (PaywallTriggersTests.testRank4ShowsOnceNotAgainWithin14DaysOnceMoreThenNever); passed in green sim 39090468266 |
| D | P1.10 | #43 | #81 | closed | merged; code-verified on main (SaveQuotaSummaryTests.testMeterTextAndVisibility); passed in green sim 39090468266 |
| D | P3.5 | #44 | #82 | closed | merged; code-verified on main (PurchaseConfirmationTests.testPurchaseFromAMIDIRowResumesTheMIDIExportExactlyOnce); passed in green sim 39090468266 |
| D | P9.4 | #45 | #83 | closed | merged; code-verified on main (ProStatusLineTests.testStatusLineForEveryKindOfEntitlement, testToolbarGoProIsHiddenForPro); passed in green sim 39090468266 |
| follow-up | - | #86 | #87 #88 #89 | open | merged; code-verified on main (ProStore entitlementSource seam, nil in production; TestDeadline removed); green sim 39090468266; owner to close |
