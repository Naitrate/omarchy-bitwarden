.pragma library

// Pure helpers for the Bitwarden widget. Command output is untrusted: every
// value that reaches the UI is validated, length-limited, and returned as
// plain strings. Secrets never pass through here; the service pipes them
// straight from `bw` into the clipboard.

function parseStatus(raw) {
  var empty = { status: "unknown", email: "", lastSync: "", serverUrl: "" }
  var text = String(raw || "").trim()
  if (text === "") return empty
  try {
    var data = JSON.parse(text)
    if (!data || typeof data !== "object" || Array.isArray(data)) return empty
    var status = String(data.status || "unknown")
    if (status !== "unauthenticated" && status !== "locked" && status !== "unlocked")
      status = "unknown"
    return {
      status: status,
      email: String(data.userEmail || "").slice(0, 200),
      lastSync: String(data.lastSync || "").slice(0, 40),
      serverUrl: String(data.serverUrl || "").slice(0, 300)
    }
  } catch (e) {
    return empty
  }
}

// `bw list items` is filtered through filter.jq before it reaches QML, so this
// only ever sees id, name, username, favorite, hasTotp, and uris.
function parseItems(raw) {
  var text = String(raw || "").trim()
  if (text === "") return []
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return []
  }
  if (!Array.isArray(data)) return []
  var out = []
  for (var i = 0; i < data.length && out.length < 5000; i++) {
    var item = data[i]
    if (!item || typeof item !== "object" || Array.isArray(item)) continue
    var id = String(item.id || "")
    if (!/^[A-Za-z0-9-]{8,64}$/.test(id)) continue
    var uris = []
    if (Array.isArray(item.uris)) {
      for (var j = 0; j < item.uris.length && uris.length < 5; j++) {
        var uri = String(item.uris[j] || "")
        if (uri.length > 0 && uri.length <= 2048) uris.push(uri)
      }
    }
    out.push({
      id: id,
      name: String(item.name || "").slice(0, 200),
      username: String(item.username || "").slice(0, 200),
      favorite: item.favorite === true,
      hasTotp: item.hasTotp === true,
      uris: uris
    })
  }
  return out
}

function filterItems(items, query, limit) {
  var out = []
  if (!Array.isArray(items)) return out
  var max = Math.max(1, Math.min(500, parseInt(limit, 10) || 100))
  var q = String(query || "").trim().toLowerCase().slice(0, 100)
  for (var i = 0; i < items.length && out.length < max; i++) {
    var item = items[i]
    if (!item) continue
    if (q === "" || itemMatches(item, q)) out.push(item)
  }
  return out
}

function itemMatches(item, q) {
  if (String(item.name || "").toLowerCase().indexOf(q) !== -1) return true
  if (String(item.username || "").toLowerCase().indexOf(q) !== -1) return true
  var uris = Array.isArray(item.uris) ? item.uris : []
  for (var i = 0; i < uris.length; i++)
    if (String(uris[i]).toLowerCase().indexOf(q) !== -1) return true
  return false
}

// Only http(s) links are opened. Control characters are stripped so a vault
// entry cannot smuggle terminal or argv tricks into xdg-open.
function safeUrl(item) {
  var uris = item && Array.isArray(item.uris) ? item.uris : []
  for (var i = 0; i < uris.length; i++) {
    var url = String(uris[i] || "").replace(/[\u0000-\u001f\u007f]/g, "").trim()
    if (url.length > 0 && url.length <= 2048 && /^https?:\/\//i.test(url)) return url
  }
  return ""
}

function isSessionKey(value) {
  return /^[A-Za-z0-9+/=_-]{16,512}$/.test(String(value || ""))
}

function classifyError(raw, exitCode) {
  var detail = String(raw || "").trim().slice(0, 300)
  var text = detail.toLowerCase()
  var code = "unknown"
  if (exitCode === 127 || text.indexOf("command not found") !== -1) {
    code = "not-installed"
  } else if (text.indexOf("not logged in") !== -1) {
    code = "unauthenticated"
  } else if (text.indexOf("vault is locked") !== -1 || text.indexOf("vault is not unlocked") !== -1) {
    code = "locked"
  } else if (text.indexOf("session") !== -1 && text.indexOf("expired") !== -1) {
    code = "session-expired"
  } else if (text.indexOf("username or password is incorrect") !== -1
      || text.indexOf("invalid master password") !== -1
      || text.indexOf("mac failed") !== -1
      || text.indexOf("decryption operation failed") !== -1
      || text.indexOf("provided key is not the expected type") !== -1) {
    code = "unlock-failed"
  } else if (text.indexOf("enotfound") !== -1
      || text.indexOf("econnrefused") !== -1
      || text.indexOf("fetch failed") !== -1
      || text.indexOf("network") !== -1
      || text.indexOf("timed out") !== -1) {
    code = "network"
  }
  return { code: code, detail: detail }
}
