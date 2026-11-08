import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// One shared Bitwarden session for every bar widget instance. The session key
// is held only in this object's memory: never written to disk, never bound to
// a visible property, and dropped the moment the vault locks. Secrets copied
// by the widget go from `bw` straight into `wl-copy` inside a shell pipeline,
// so they do not pass through QML.
Item {
  id: root

  property bool installed: true
  property string status: "unknown"   // unauthenticated | locked | unlocked | unknown
  property string email: ""
  property string lastSync: ""
  property var items: []
  property bool loading: false
  property string errorCode: ""
  property string errorDetail: ""
  property string noticeCode: ""
  property int noticeSeconds: 0
  property bool pinConfigured: false
  property bool pinBusy: false
  property string pinErrorCode: ""
  property string pinErrorDetail: ""
  property int pinRevision: 0

  // Private session state. `_sessionKey` is the only copy of the key.
  property string _sessionKey: ""
  property bool _itemsLoaded: false
  property int _epoch: 0
  property int _statusEpoch: 0
  property bool _syncTimedOut: false
  property string _copyField: ""
  property int _copySeconds: 30
  property double _loginPollUntil: 0
  property string _pinAction: ""
  property string _pinPayload: ""

  readonly property bool unlocked: status === "unlocked" && _sessionKey !== ""
  // A vault unlocked by another terminal has no key here, so the widget must
  // ask for the master password before it can do anything.
  readonly property bool locked: status === "locked" || (status === "unlocked" && _sessionKey === "")
  readonly property bool unauthenticated: status === "unauthenticated"
  readonly property bool itemsLoaded: _itemsLoaded
  readonly property bool busy: unlockProc.running || listProc.running || syncProc.running
    || lockProc.running || copyProc.running
  // English for IPC and diagnostics; the bar widget owns translated text.
  readonly property string statusText: status

  readonly property string filterPath: {
    var path = Qt.resolvedUrl("filter.jq").toString().replace(/^file:\/\//, "")
    try { return decodeURIComponent(path) } catch (e) { return path }
  }

  readonly property string pinScriptPath: {
    var path = Qt.resolvedUrl("pin.py").toString().replace(/^file:\/\//, "")
    try { return decodeURIComponent(path) } catch (e) { return path }
  }

  function clearError() {
    errorCode = ""
    errorDetail = ""
  }

  function setError(code, detail) {
    errorCode = String(code || "unknown")
    errorDetail = String(detail || "").slice(0, 300)
    noticeCode = ""
    noticeSeconds = 0
    noticeTimer.stop()
  }

  function setNotice(code, seconds) {
    noticeCode = String(code || "")
    noticeSeconds = Math.max(0, Math.min(300, parseInt(seconds, 10) || 0))
    errorCode = ""
    errorDetail = ""
    clearPinError()
    noticeTimer.restart()
  }

  function clearPinError() {
    pinErrorCode = ""
    pinErrorDetail = ""
  }

  function setPinError(code, detail) {
    pinErrorCode = String(code || "pin-failed")
    pinErrorDetail = String(detail || "").slice(0, 300)
    noticeCode = ""
    noticeSeconds = 0
    noticeTimer.stop()
  }

  function pinErrorFor(error) {
    var code = String(error || "")
    if (code === "wrong-pin") return "wrong-pin"
    if (code === "not-configured") return "not-configured"
    if (code === "bad-pin") return "bad-pin"
    if (code === "bad-email") return "no-account"
    if (code === "bad-master") return "bad-master"
    if (code === "keyring-store-failed" || code === "keyring-lookup-failed") return "keyring"
    if (code === "encrypt-failed" || code === "decrypt-failed"
        || code === "bad-blob" || code === "bad-session") return "pin-failed"
    if (code === "bw-failed") return "bw-failed"
    if (code === "timeout") return "timeout"
    return "pin-failed"
  }

  function runPin(action, payload) {
    if (pinProc.running) return false
    pinBusy = true
    clearPinError()
    _pinAction = String(action || "")
    _pinPayload = JSON.stringify(payload || {}) + "\n"
    pinProc.stdinEnabled = true
    pinProc.command = ["python3", pinScriptPath, _pinAction]
    pinProc.running = true
    return true
  }

  function refreshPinStatus() {
    if (email === "" || !installed) {
      pinConfigured = false
      return
    }
    if (pinProc.running) return
    runPin("status", { email: email })
  }

  function setPin(master, pin) {
    if (email === "") {
      setPinError("no-account", "")
      return
    }
    var value = String(pin || "")
    if (!/^[0-9]{6,12}$/.test(value)) {
      setPinError("bad-pin", "")
      return
    }
    var secret = String(master || "")
    if (secret.length === 0) {
      setPinError("bad-master", "")
      return
    }
    runPin("set", { email: email, pin: value, master: secret })
  }

  function clearPin() {
    if (email === "") {
      setPinError("no-account", "")
      return
    }
    runPin("clear", { email: email })
  }

  function unlockWithPin(pin) {
    if (email === "") {
      setPinError("no-account", "")
      return
    }
    var value = String(pin || "")
    if (!/^[0-9]{6,12}$/.test(value)) {
      setPinError("bad-pin", "")
      return
    }
    _sessionKey = ""
    items = []
    _itemsLoaded = false
    _epoch += 1
    _statusEpoch += 1
    runPin("get", { email: email, pin: value })
  }

  function finishUnlock(sessionKey) {
    _sessionKey = String(sessionKey || "")
    status = "unlocked"
    clearError()
    clearPinError()
    loadItems()
  }

  function applyStatus(parsed) {
    var next = parsed && parsed.status ? String(parsed.status) : "unknown"
    if (next !== "unlocked") {
      _sessionKey = ""
      items = []
      _itemsLoaded = false
      _epoch += 1
    } else if (_sessionKey === "") {
      // Unlocked elsewhere, but this service has no key to use it.
      items = []
      _itemsLoaded = false
    }
    status = next
    var previousEmail = email
    email = parsed && parsed.email ? String(parsed.email).slice(0, 200) : ""
    lastSync = parsed && parsed.lastSync ? String(parsed.lastSync).slice(0, 40) : ""
    if (email !== previousEmail) refreshPinStatus()
  }

  function refreshStatus() {
    if (statusProc.running) return
    _statusEpoch += 1
    statusProc._epoch = _statusEpoch
    // With a session key, `bw status` can see the vault is unlocked. Without
    // one it reports "locked" even while this service holds a valid session.
    statusProc.environment = _sessionKey !== "" ? ({ BW_SESSION: _sessionKey }) : ({})
    statusProc.running = true
  }

  function unlock(password) {
    if (!installed || unlockProc.running) return
    var value = String(password || "")
    if (value.length === 0) {
      setError("unlock-empty", "")
      return
    }
    _sessionKey = ""
    _epoch += 1
    _statusEpoch += 1
    clearError()
    unlockProc.environment = ({ BW_PASSWORD: value })
    unlockProc.command = ["bash", "-c", "bw unlock --passwordenv BW_PASSWORD --raw"]
    unlockProc.running = true
  }

  function loadItems() {
    if (!unlocked || listProc.running) return
    loading = true
    clearError()
    listProc._epoch = _epoch
    listProc.command = ["bash", "-c",
      "set -o pipefail; bw list items | jq -c -f " + Util.shellQuote(filterPath)]
    listProc.environment = ({ BW_SESSION: _sessionKey })
    listProc.running = true
  }

  function sync() {
    if (!unlocked || syncProc.running) return
    clearError()
    _syncTimedOut = false
    syncProc.environment = ({ BW_SESSION: _sessionKey })
    syncProc.command = ["bash", "-c", "bw sync"]
    syncProc.running = true
    syncTimeout.restart()
  }

  function lock() {
    if (lockProc.running) return
    clearError()
    lockProc.environment = ({ BW_SESSION: _sessionKey })
    lockProc.command = ["bash", "-c", "bw lock"]
    lockProc.running = true
  }

  function login() {
    clearError()
    Quickshell.execDetached(["omarchy-launch-terminal", "bw", "login"])
    setNotice("login-opened", 0)
    _loginPollUntil = Date.now() + 120000
    loginPoll.start()
  }

  function copyPassword(item, seconds) {
    copyField("password", item, seconds)
  }

  function copyTotp(item, seconds) {
    copyField("totp", item, seconds)
  }

  function copyField(field, item, seconds) {
    if (!unlocked || copyProc.running) return
    var id = item ? String(item.id || "") : ""
    if (!/^[A-Za-z0-9-]{8,64}$/.test(id)) {
      setError("copy-failed", "")
      return
    }
    _copyField = field === "totp" ? "totp" : "password"
    _copySeconds = Math.max(5, Math.min(300, parseInt(seconds, 10) || 30))
    clearError()
    copyProc.command = ["bash", "-c", copyCommand(_copyField, id, _copySeconds)]
    copyProc.environment = ({ BW_SESSION: _sessionKey })
    copyProc.running = true
  }

  // The secret stays inside the shell: `bw` writes it to a variable, wl-copy
  // reads it from a pipe, and a detached subshell clears the clipboard later
  // only if it still holds the same value.
  function copyCommand(field, id, seconds) {
    var getter = field === "totp" ? "totp" : "password"
    var secs = Math.max(5, Math.min(300, parseInt(seconds, 10) || 30))
    return "set -o pipefail; "
      + "secret=$(bw get " + getter + " " + Util.shellQuote(id) + ") || exit 1; "
      + "[ -n \"$secret\" ] || exit 2; "
      + "printf %s \"$secret\" | wl-copy --sensitive || exit 3; "
      + "( unset BW_SESSION; sleep " + secs + "; "
      + "current=$(wl-paste --no-newline 2>/dev/null); "
      + "if [ \"$current\" = \"$secret\" ]; then wl-copy --clear; fi ) "
      + ">/dev/null 2>&1 </dev/null &"
  }

  function copyUsername(item) {
    var username = item ? String(item.username || "") : ""
    if (username === "") {
      setError("copy-failed", "")
      return
    }
    clearError()
    Quickshell.execDetached(["wl-copy", "--sensitive", "--", username])
    setNotice("copied-username", 0)
  }

  function openUrl(item) {
    var url = Model.safeUrl(item)
    if (url === "") return
    clearError()
    Quickshell.execDetached(["xdg-open", url])
  }

  Component.onCompleted: refreshStatus()

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.refreshStatus()
  }

  Timer {
    id: noticeTimer
    interval: 4000
    onTriggered: {
      root.noticeCode = ""
      root.noticeSeconds = 0
    }
  }

  Timer {
    id: loginPoll
    interval: 3000
    repeat: true
    onTriggered: {
      if (Date.now() > root._loginPollUntil || root.status !== "unauthenticated") {
        running = false
        return
      }
      root.refreshStatus()
    }
  }

  Timer {
    id: syncTimeout
    interval: 60000
    onTriggered: {
      if (!syncProc.running) return
      root._syncTimedOut = true
      syncProc.running = false
    }
  }

  Process {
    id: statusProc
    property int _epoch: 0
    command: ["bash", "-c", "bw status"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      statusProc.environment = ({})
      if (statusProc._epoch !== root._statusEpoch) return
      if (exitCode === 127) {
        root.installed = false
        root.status = "unknown"
        return
      }
      root.installed = true
      if (exitCode !== 0) {
        var err = Model.classifyError(statusErr.text, exitCode)
        if (err.code === "unauthenticated") {
          root.applyStatus({ status: "unauthenticated" })
          return
        }
        if (err.code === "locked") {
          root.applyStatus({ status: "locked" })
          return
        }
        root.setError(err.code, err.detail)
        return
      }
      root.applyStatus(Model.parseStatus(statusOut.text))
    }
  }

  Process {
    id: unlockProc
    stdout: StdioCollector { id: unlockOut; waitForEnd: true }
    stderr: StdioCollector { id: unlockErr; waitForEnd: true }
    onExited: function(exitCode) {
      unlockProc.environment = ({})
      if (exitCode !== 0) {
        var err = Model.classifyError(unlockErr.text, exitCode)
        root._sessionKey = ""
        root.setError(err.code === "unknown" ? "unlock-failed" : err.code, err.detail)
        return
      }
      var lines = String(unlockOut.text || "").trim().split(/\r?\n/)
      var key = lines.length > 0 ? lines[lines.length - 1].trim() : ""
      if (!Model.isSessionKey(key)) {
        root._sessionKey = ""
        root.setError("unlock-failed", "")
        return
      }
      root.finishUnlock(key)
    }
  }

  Process {
    id: listProc
    property int _epoch: 0
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    stderr: StdioCollector { id: listErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      listProc.environment = ({})
      if (listProc._epoch !== root._epoch) return
      if (exitCode !== 0) {
        var err = Model.classifyError(listErr.text, exitCode)
        if (err.code === "locked" || err.code === "session-expired" || err.code === "unauthenticated") {
          root._sessionKey = ""
          root.items = []
          root._itemsLoaded = false
          root._epoch += 1
          root.status = err.code === "unauthenticated" ? "unauthenticated" : "locked"
          root.setError(err.code, err.detail)
        } else {
          root.setError(err.code === "unknown" ? "list-failed" : err.code, err.detail)
        }
        return
      }
      root.items = Model.parseItems(listOut.text)
      root._itemsLoaded = true
      root.clearError()
    }
  }

  Process {
    id: syncProc
    stdout: StdioCollector { id: syncOut; waitForEnd: true }
    stderr: StdioCollector { id: syncErr; waitForEnd: true }
    onExited: function(exitCode) {
      syncTimeout.stop()
      syncProc.environment = ({})
      if (root._syncTimedOut) {
        root._syncTimedOut = false
        root.setError("timeout", "")
        return
      }
      if (exitCode !== 0) {
        var err = Model.classifyError(syncErr.text, exitCode)
        root.setError(err.code === "unknown" ? "sync-failed" : err.code, err.detail)
        if (err.code === "locked" || err.code === "session-expired" || err.code === "unauthenticated")
          root.refreshStatus()
        return
      }
      root.setNotice("synced", 0)
      root.loadItems()
    }
  }

  Process {
    id: lockProc
    stdout: StdioCollector { id: lockOut; waitForEnd: true }
    stderr: StdioCollector { id: lockErr; waitForEnd: true }
    onExited: function(exitCode) {
      lockProc.environment = ({})
      root._sessionKey = ""
      root.items = []
      root._itemsLoaded = false
      root._epoch += 1
      root._statusEpoch += 1
      root.status = "locked"
      if (exitCode === 0) {
        root.setNotice("locked", 0)
        return
      }
      var err = Model.classifyError(lockErr.text, exitCode)
      if (err.code !== "locked")
        root.setError(err.code === "unknown" ? "lock-failed" : err.code, err.detail)
    }
  }

  Process {
    id: copyProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: copyErr; waitForEnd: true }
    onExited: function(exitCode) {
      copyProc.environment = ({})
      if (exitCode === 0) {
        root.setNotice(root._copyField === "totp" ? "copied-totp" : "copied-password", root._copySeconds)
        return
      }
      if (exitCode === 2 || exitCode === 3) {
        root.setError("copy-failed", "")
        return
      }
      var err = Model.classifyError(copyErr.text, exitCode)
      root.setError(err.code === "unknown" ? "copy-failed" : err.code, err.detail)
      if (err.code === "locked" || err.code === "session-expired" || err.code === "unauthenticated")
        root.refreshStatus()
    }
  }

  Process {
    id: pinProc
    stdinEnabled: true
    stdout: StdioCollector { id: pinOut; waitForEnd: true }
    stderr: StdioCollector { id: pinErr; waitForEnd: true }
    onStarted: {
      if (root._pinPayload !== "") {
        write(root._pinPayload)
        root._pinPayload = ""
      }
    }
    onExited: function(exitCode) {
      stdinEnabled = false
      // Let the process finish exiting before re-enabling PIN actions, so a
      // click in the same turn cannot be dropped by runPin's running check.
      Qt.callLater(function() { root.pinBusy = false })
      var action = root._pinAction
      root._pinAction = ""
      var raw = String(pinOut.text || "").trim()
      var result = null
      try { result = JSON.parse(raw) } catch (e) { result = null }
      if (!result || typeof result !== "object" || Array.isArray(result)) {
        if (action === "status") {
          root.pinConfigured = false
          return
        }
        root.setPinError("pin-failed", String(pinErr.text || "").slice(0, 200))
        return
      }
      if (action === "status") {
        root.pinConfigured = result.ok === true && result.enabled === true
        return
      }
      if (action === "clear") {
        if (result.ok === true) {
          root.pinConfigured = false
          root.pinRevision += 1
          root.setNotice("pin-disabled", 0)
        } else {
          root.setPinError(root.pinErrorFor(result.error), result.detail)
        }
        return
      }
      if (action === "set") {
        if (result.ok === true) {
          root.pinConfigured = true
          root.pinRevision += 1
          root.setNotice("pin-enabled", 0)
        } else {
          root.setPinError(root.pinErrorFor(result.error), result.detail)
        }
        return
      }
      if (action === "get") {
        if (result.ok === true && Model.isSessionKey(result.session)) {
          root.finishUnlock(String(result.session))
          return
        }
        if (result.ok === true) {
          root.setPinError("pin-failed", "")
          return
        }
        var code = root.pinErrorFor(result.error)
        if (code === "bw-failed") {
          var err = Model.classifyError(result.detail, 1)
          if (err.code === "unauthenticated") {
            root.applyStatus({ status: "unauthenticated" })
            return
          }
          if (err.code === "unlock-failed") {
            root.setPinError("stale-master", err.detail)
            return
          }
          root.setPinError(err.code === "unknown" ? "pin-failed" : err.code, err.detail)
          return
        }
        if (code === "not-configured") root.pinConfigured = false
        root.setPinError(code, result.detail)
      }
    }
  }
}
