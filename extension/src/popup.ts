// Popup UI. Will host the kill switch that toggles `enabled` in
// chrome.storage.local (see docs/architecture.md).

const status = document.getElementById("status");
if (status) {
  status.textContent = "Not connected";
}
