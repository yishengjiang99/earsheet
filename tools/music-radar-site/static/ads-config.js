// Ad pixel settings. deploy-grepawk.sh rewrites this file from env vars at deploy time
// (ADS_TRACKING_ENABLED, MUSIC_X_PIXEL_ID, MUSIC_X_EVENT_ID_PURCHASE, MUSIC_X_EVENT_ID_START_TRIAL,
// MUSIC_X_EVENT_ID_LEAD, MUSIC_REDDIT_PIXEL_ID). Empty id = that pixel is not loaded.
window.MR_ADS = {"enabled":false,"xPixelId":"","xPurchaseEventId":"","xStartTrialEventId":"","xLeadEventId":"","redditPixelId":""};
