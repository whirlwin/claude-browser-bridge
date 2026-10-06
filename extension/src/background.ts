// MV3 service worker. Will own the native messaging port to `cbb host` and
// dispatch requests to chrome.* APIs (see docs/architecture.md).

chrome.runtime.onInstalled.addListener(() => {
  console.info("Claude Browser Bridge installed");
});
