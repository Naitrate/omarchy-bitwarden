import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bitwarden bar widget and keyboard panel. The vault session lives in the
// sibling Service.qml so every monitor shares one unlock; this file only
// renders state and asks the service to act.
Panel {
  id: root
  moduleName: "naitrate.bitwarden"
  ipcTarget: "naitrate.bitwarden"
  manageIpc: false

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("naitrate.bitwarden") : null
  readonly property bool serviceReady: service !== null
  readonly property string status: service ? String(service.status || "unknown") : "unknown"
  readonly property bool unlocked: service ? service.unlocked === true : false
  readonly property bool locked: service ? service.locked === true : false
  readonly property bool unauthenticated: service ? service.unauthenticated === true : false
  readonly property bool installed: service ? service.installed !== false : true
  readonly property bool busy: service ? service.busy === true : false
  readonly property bool itemsLoading: service ? service.loading === true : false
  readonly property var items: service && service.items ? service.items : []
  readonly property string errorCode: service ? String(service.errorCode || "") : ""
  readonly property string errorDetail: {
    var detail = service ? String(service.errorDetail || "") : ""
    var address = email()
    if ((hideEmail || privacyMode) && address !== "")
      detail = detail.split(address).join("•••")
    return detail
  }
  readonly property string noticeCode: service ? String(service.noticeCode || "") : ""
  readonly property int noticeSeconds: service ? (service.noticeSeconds || 0) : 0
  readonly property bool pinConfigured: service ? service.pinConfigured === true : false
  readonly property bool pinBusy: service ? service.pinBusy === true : false
  readonly property string pinErrorCode: service ? String(service.pinErrorCode || "") : ""
  readonly property string pinErrorDetail: service ? String(service.pinErrorDetail || "") : ""
  readonly property int pinRevision: service ? (service.pinRevision || 0) : 0
  readonly property int clearSeconds: Math.max(5, Math.min(300, parseInt(setting("clipboardClearSeconds", 30), 10) || 30))
  readonly property bool hideEmail: {
    var value = setting("hideEmail", false)
    return value === true || String(value) === "true"
  }

  property string query: ""
  property bool cursorActive: false
  property int itemIndex: 0
  property bool pinSetupOpen: false
  property bool showMasterUnlock: false
  property bool showSecrets: false
  property bool privacyMode: false
  readonly property var filteredItems: Model.filterItems(items, query, 100)
  readonly property var selectedItem: itemIndex >= 0 && itemIndex < filteredItems.length
    ? filteredItems[itemIndex] : null

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function statusLabel() {
    if (!serviceReady) return strings.t("status.unknown")
    if (!installed) return strings.t("status.notInstalled")
    var hide = hideEmail || privacyMode
    if (unlocked) return hide || email() === ""
      ? strings.t("status.unlocked") : strings.t("status.unlockedAs").arg(email())
    if (locked) return hide || email() === ""
      ? strings.t("status.locked") : strings.t("status.lockedAs").arg(email())
    if (unauthenticated) return strings.t("status.unauthenticated")
    return strings.t("status.unknown")
  }

  function email() {
    return service ? String(service.email || "") : ""
  }

  function errorText() {
    if (errorCode === "") return ""
    var key = "error." + errorCode
    var text = strings.t(key)
    return text === key ? strings.t("error.unknown") : text
  }

  function pinErrorText() {
    if (pinErrorCode === "") return ""
    var key = "pin.error." + pinErrorCode
    var text = strings.t(key)
    return text === key ? strings.t("pin.error.unknown") : text
  }

  function noticeText() {
    if (noticeCode === "") return ""
    if (noticeCode === "copied-password") return strings.t("notice.copiedPassword").arg(noticeSeconds)
    if (noticeCode === "copied-totp") return strings.t("notice.copiedTotp").arg(noticeSeconds)
    if (noticeCode === "copied-username") return strings.t("notice.copiedUsername")
    if (noticeCode === "synced") return strings.t("notice.synced")
    if (noticeCode === "locked") return strings.t("notice.locked")
    if (noticeCode === "login-opened") return strings.t("notice.loginOpened")
    if (noticeCode === "pin-enabled") return strings.t("notice.pinEnabled")
    if (noticeCode === "pin-disabled") return strings.t("notice.pinDisabled")
    return ""
  }

  function refresh() {
    if (!service) return
    service.refreshStatus()
    service.refreshPinStatus()
    if (service.unlocked && !service.itemsLoaded) service.loadItems()
  }

  function login() {
    if (service) service.login()
  }

  function unlock(password) {
    if (service) service.unlock(password)
  }

  function lock() {
    if (service) service.lock()
  }

  function sync() {
    if (service) service.sync()
  }

  function setPin(master, pin) {
    if (service) service.setPin(master, pin)
  }

  function clearPin() {
    if (service) service.clearPin()
  }

  function unlockWithPin(pin) {
    if (service) service.unlockWithPin(pin)
  }

  function clearPinError() {
    if (service) service.clearPinError()
  }

  function copyPasswordFor(item) {
    if (service && item) service.copyPassword(item, clearSeconds)
  }

  function copyTotpFor(item) {
    if (service && item) service.copyTotp(item, clearSeconds)
  }

  function copyUsernameFor(item) {
    if (service && item) service.copyUsername(item)
  }

  function openUrlFor(item) {
    if (service && item) service.openUrl(item)
  }

  function focusList() {
    if (panel.loadedContent) panel.loadedContent.focusList()
  }

  onFilteredItemsChanged: {
    if (itemIndex >= filteredItems.length)
      itemIndex = Math.max(0, filteredItems.length - 1)
    if (filteredItems.length === 0) cursorActive = false
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      scheduleFocus("initial")
    } else {
      query = ""
      cursorActive = false
      itemIndex = 0
      pinSetupOpen = false
      showMasterUnlock = false
      showSecrets = false
      if (panel.loadedContent) {
        panel.loadedContent.clearSearch()
        panel.loadedContent.clearUnlock()
        panel.loadedContent.clearPinFields()
      }
    }
  }

  onPinRevisionChanged: {
    if (pinSetupOpen) pinSetupOpen = false
    showMasterUnlock = false
  }
  onPinConfiguredChanged: if (opened && locked) scheduleFocus("locked")
  onPinSetupOpenChanged: if (opened && unlocked) scheduleFocus("afterUnlock")
  onUnlockedChanged: if (opened && unlocked) scheduleFocus("afterUnlock")
  onLockedChanged: if (opened && locked) scheduleFocus("locked")

  property string _focusMode: "initial"

  function scheduleFocus(mode) {
    _focusMode = String(mode || "initial")
    focusNow.restart()
  }

  // One millisecond, not a visible delay: it runs after the panel's own
  // focusTarget has been applied, so the first typed character lands in the
  // field instead of being lost to the key catcher.
  Timer {
    id: focusNow
    interval: 1
    onTriggered: {
      if (!root.opened || !panel.loadedContent) return
      if (root._focusMode === "locked") panel.loadedContent.focusLocked()
      else if (root._focusMode === "afterUnlock") panel.loadedContent.focusAfterUnlock()
      else panel.loadedContent.focusInitial()
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function lock(): string { root.lock(); return "ok" }
    function sync(): string { root.sync(); return "ok" }
    function status(): string { return root.service ? root.service.statusText : "unknown" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    foreground: root.barForeground
    tooltipText: root.statusLabel()
    iconComponent: Component {
      Item {
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        opacity: root.unlocked ? 1.0 : 0.55

        Image {
          id: barLogoMask
          anchors.fill: parent
          source: Qt.resolvedUrl("bitwarden-shield.svg")
          sourceSize.width: 64
          sourceSize.height: 64
          fillMode: Image.PreserveAspectFit
          smooth: true
          visible: false
          layer.enabled: true
        }

        Rectangle {
          anchors.fill: parent
          color: root.barForeground
          layer.enabled: true
          layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: barLogoMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (root.unlocked) root.lock()
        else if (root.unauthenticated) root.login()
        else root.toggle()
      } else if (buttonCode === Qt.MiddleButton) {
        root.refresh()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(560))

    content: PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      blocked: unlockField.field.activeFocus || searchField.activeFocus
        || pinUnlockField.field.activeFocus || pinMasterField.field.activeFocus
        || pinNewField.field.activeFocus || pinConfirmField.field.activeFocus

      function focusInitial() {
        if (root.locked) focusLocked()
        else if (root.unlocked) focusAfterUnlock()
        else keyCatcher.forceActiveFocus()
      }

      function focusAfterUnlock() {
        if (root.pinSetupOpen) focusPinSetup()
        else focusSearch()
      }

      function focusLocked() {
        if (root.pinConfigured && !root.showMasterUnlock) focusPin()
        else focusUnlock()
      }

      function focusSearch() {
        searchField.forceActiveFocus()
        searchField.selectAll()
      }

      function focusUnlock() {
        unlockField.field.forceActiveFocus()
      }

      function focusPin() {
        pinUnlockField.field.forceActiveFocus()
      }

      function focusPinSetup() {
        pinMasterField.field.forceActiveFocus()
      }

      function focusList() {
        keyCatcher.forceActiveFocus()
      }

      function clearSearch() {
        searchField.text = ""
      }

      function clearUnlock() {
        unlockField.text = ""
      }

      function clearPinFields() {
        pinUnlockField.text = ""
        pinMasterField.text = ""
        pinNewField.text = ""
        pinConfirmField.text = ""
      }

      function submitPin() {
        if (root.pinBusy) return
        var pin = String(pinUnlockField.text || "")
        pinUnlockField.text = ""
        if (pin.length > 0) root.unlockWithPin(pin)
      }

      function submitSetPin() {
        if (root.pinBusy) return
        var master = String(pinMasterField.text || "")
        var pin = String(pinNewField.text || "")
        var confirm = String(pinConfirmField.text || "")
        if (master.length === 0 || pin.length < 6 || pin !== confirm) return
        root.setPin(master, pin)
        pinMasterField.text = ""
        pinNewField.text = ""
        pinConfirmField.text = ""
      }

      function removePin() {
        if (!root.pinBusy) root.clearPin()
      }

      function moveCursor(dx, dy) {
        if (!root.unlocked || root.filteredItems.length === 0) return
        root.cursorActive = true
        var step = dy !== 0 ? dy : dx
        root.itemIndex = Math.max(0, Math.min(root.filteredItems.length - 1, root.itemIndex + step))
        ensureCursorVisible()
      }

      function ensureCursorVisible() {
        var row = itemRepeater.itemAt(root.itemIndex)
        if (!row || !panelFlick || !panelFlick.contentItem) return
        var top = row.mapToItem(panelFlick.contentItem, 0, 0).y
        var bottom = top + row.height
        var viewTop = panelFlick.contentY
        var viewBottom = viewTop + panelFlick.height
        if (top < viewTop) panelFlick.contentY = Math.max(0, top - Style.space(8))
        else if (bottom > viewBottom) panelFlick.contentY = bottom - panelFlick.height + Style.space(8)
      }

      onMoveRequested: function(dx, dy) {
        if (!root.unlocked) return
        if (!root.cursorActive) { root.cursorActive = true; return }
        moveCursor(dx, dy)
      }

      onActivateRequested: {
        if (root.locked) { focusLocked(); return }
        if (root.unauthenticated) { root.login(); return }
        if (root.unlocked && root.pinSetupOpen) { focusPinSetup(); return }
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (root.selectedItem) root.copyPasswordFor(root.selectedItem)
      }

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      onTextKey: function(t, modifiers) {
        // If a field has focus the key catcher is blocked and never sees the
        // key. These branches catch the first keystroke typed before the
        // one-millisecond focus lands, so it is not swallowed as a shortcut.
        if (root.locked) {
          if (root.pinConfigured && !root.showMasterUnlock) {
            focusPin()
            pinUnlockField.field.insertAt(pinUnlockField.field.cursorPosition, t)
          } else {
            focusUnlock()
            unlockField.field.insertAt(unlockField.field.cursorPosition, t)
          }
          return
        }
        if (root.unlocked && root.pinSetupOpen) {
          if (!pinMasterField.field.activeFocus && !pinNewField.field.activeFocus && !pinConfirmField.field.activeFocus) {
            focusPinSetup()
            pinMasterField.field.insertAt(pinMasterField.field.cursorPosition, t)
          }
          return
        }
        if (!root.unlocked) return
        if (t === "/") { focusSearch(); return }
        if (t === "c" || t === "C") { root.copyPasswordFor(root.selectedItem); return }
        if (t === "u" || t === "U") { root.copyUsernameFor(root.selectedItem); return }
        if (t === "t" || t === "T") { root.copyTotpFor(root.selectedItem); return }
        if (t === "o" || t === "O") { root.openUrlFor(root.selectedItem); return }
        if (t === "s" || t === "S") { root.sync(); return }
        if (t === "L") { root.lock(); return }
        if (t === "r" || t === "R") { root.refresh(); return }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: strings.t("panel.title")
            meta: root.statusLabel()
            detail: root.unlocked && !root.itemsLoading
              ? strings.tn("panel.items", root.items.length).arg(Commons.I18n.formatNumber(root.items.length))
              : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.unlocked ? 1.0 : 0.55
            iconComponent: Component {
              Item {
                width: Style.font.display
                height: Style.font.display

                Image {
                  id: heroLogoMask
                  anchors.fill: parent
                  source: Qt.resolvedUrl("bitwarden-shield.svg")
                  sourceSize.width: 128
                  sourceSize.height: 128
                  fillMode: Image.PreserveAspectFit
                  smooth: true
                  visible: false
                  layer.enabled: true
                }

                Rectangle {
                  anchors.fill: parent
                  color: root.foreground
                  layer.enabled: true
                  layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: heroLogoMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                  }
                }
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(2)
                visible: root.serviceReady
                PanelActionButton {
                  visible: root.serviceReady && !root.hideEmail
                  iconText: root.privacyMode ? "󰈉" : "󰈈"
                  tooltipText: root.privacyMode ? strings.t("panel.showEmail") : strings.t("panel.hideEmail")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.privacyMode = !root.privacyMode
                }
                PanelActionButton {
                  visible: root.unlocked
                  iconText: "󰑓"
                  tooltipText: strings.t("panel.sync")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: root.unlocked && !root.busy
                  onClicked: root.sync()
                }
                PanelActionButton {
                  visible: root.unlocked
                  iconText: "󰌆"
                  tooltipText: root.pinConfigured ? strings.t("pin.changeButton") : strings.t("pin.setButton")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: root.unlocked && !root.busy && !root.pinBusy
                  onClicked: root.pinSetupOpen = !root.pinSetupOpen
                }
                PanelActionButton {
                  visible: root.unlocked
                  iconText: "󰌾"
                  tooltipText: strings.t("panel.lock")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: root.unlocked && !root.busy
                  onClicked: root.lock()
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.errorCode !== ""
            width: parent.width
            text: root.errorText()
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: root.errorDetail !== ""
            width: parent.width
            text: root.errorDetail
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            visible: root.noticeText() !== ""
            width: parent.width
            text: root.noticeText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            visible: !root.serviceReady
            width: parent.width
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("panel.serviceUnavailable")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }

          Column {
            visible: root.serviceReady && !root.installed
            width: parent.width
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("panel.notInstalled")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("panel.notInstalledHint")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          Column {
            visible: root.serviceReady && root.installed && root.unauthenticated
            width: parent.width
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("panel.loginHint")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              width: parent.width
              text: strings.t("panel.login")
              iconText: "󰌆"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.login()
            }
          }

          Column {
            visible: root.serviceReady && root.installed && root.locked
            width: parent.width
            spacing: Style.space(8)

            Column {
              visible: root.pinConfigured && !root.showMasterUnlock
              width: parent.width
              spacing: Style.space(8)

              SecretField {
                id: pinUnlockField
                width: parent.width
                placeholderText: strings.t("pin.pin")
                inputMethodHints: Qt.ImhDigitsOnly
                validator: RegularExpressionValidator { regularExpression: /^[0-9]{0,12}$/ }
                onTextEdited: if (root.pinErrorCode !== "") root.clearPinError()
                onAccepted: submitPin()
              }

              Button {
                width: parent.width
                text: strings.t("pin.unlock")
                iconText: "󰌿"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: pinUnlockField.text.length >= 6 && !root.pinBusy
                onClicked: submitPin()
              }

              Button {
                width: parent.width
                text: strings.t("pin.useMaster")
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: {
                  root.showMasterUnlock = true
                  focusUnlock()
                }
              }
            }

            Column {
              visible: !root.pinConfigured || root.showMasterUnlock
              width: parent.width
              spacing: Style.space(8)

              SecretField {
                id: unlockField
                width: parent.width
                placeholderText: strings.t("panel.masterPassword")
                onAccepted: {
                  root.unlock(text)
                  text = ""
                }
              }

              Button {
                width: parent.width
                text: strings.t("panel.unlock")
                iconText: "󰌿"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: unlockField.text.length > 0 && !root.busy
                onClicked: {
                  root.unlock(unlockField.text)
                  unlockField.text = ""
                }
              }

              Button {
                visible: root.pinConfigured
                width: parent.width
                text: strings.t("pin.usePin")
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: {
                  root.showMasterUnlock = false
                  focusPin()
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.pinErrorCode !== ""
              width: parent.width
              text: root.pinErrorText()
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              visible: root.pinErrorDetail !== ""
              width: parent.width
              text: root.pinErrorDetail
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              maximumLineCount: 3
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              visible: root.pinBusy
              width: parent.width
              text: strings.t("pin.busy")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          PanelSeparator {
            visible: root.serviceReady && root.installed && root.unlocked
            foreground: root.foreground
          }

          Column {
            visible: root.serviceReady && root.installed && root.unlocked && !root.pinSetupOpen
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: searchField
              width: parent.width
              placeholderText: strings.t("panel.search")
              foreground: root.foreground
              onTextChanged: {
                root.query = text
                if (root.opened) {
                  root.itemIndex = 0
                  root.cursorActive = true
                }
              }
              onAccepted: focusList()
              Keys.onEscapePressed: root.close()
            }

            Text {
              textFormat: Text.PlainText
              visible: root.filteredItems.length === 0 && !root.itemsLoading
              width: parent.width
              text: root.query !== "" ? strings.t("panel.noMatches") : strings.t("panel.empty")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              visible: root.itemsLoading && root.items.length === 0
              width: parent.width
              text: strings.t("panel.loading")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                id: itemRepeater
                model: root.filteredItems
                ItemRow {
                  required property var modelData
                  required property int index
                  width: parent.width
                  item: modelData
                  rowIndex: index
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("panel.hint")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            visible: root.serviceReady && root.installed && root.unlocked && root.pinSetupOpen
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("pin.setTitle")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("pin.setDescription")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("pin.warning")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            SecretField {
              id: pinMasterField
              width: parent.width
              placeholderText: strings.t("pin.masterPassword")
              onTextEdited: if (root.pinErrorCode !== "") root.clearPinError()
              onAccepted: pinNewField.field.forceActiveFocus()
            }

            SecretField {
              id: pinNewField
              width: parent.width
              placeholderText: strings.t("pin.newPin")
              inputMethodHints: Qt.ImhDigitsOnly
              validator: RegularExpressionValidator { regularExpression: /^[0-9]{0,12}$/ }
              onTextEdited: if (root.pinErrorCode !== "") root.clearPinError()
              onAccepted: pinConfirmField.field.forceActiveFocus()
            }

            SecretField {
              id: pinConfirmField
              width: parent.width
              placeholderText: strings.t("pin.confirmPin")
              inputMethodHints: Qt.ImhDigitsOnly
              validator: RegularExpressionValidator { regularExpression: /^[0-9]{0,12}$/ }
              onTextEdited: if (root.pinErrorCode !== "") root.clearPinError()
              onAccepted: submitSetPin()
            }

            Text {
              textFormat: Text.PlainText
              visible: root.pinErrorCode !== ""
              width: parent.width
              text: root.pinErrorText()
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              visible: root.pinErrorDetail !== ""
              width: parent.width
              text: root.pinErrorDetail
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              maximumLineCount: 3
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              visible: root.pinBusy
              width: parent.width
              text: strings.t("pin.saving")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              width: parent.width
              text: root.pinConfigured ? strings.t("pin.change") : strings.t("pin.enable")
              iconText: "󰌆"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: pinMasterField.text.length > 0
                && pinNewField.text.length >= 6
                && pinNewField.text === pinConfirmField.text
                && !root.pinBusy
              onClicked: submitSetPin()
            }

            Button {
              visible: root.pinConfigured
              width: parent.width
              text: strings.t("pin.remove")
              foreground: root.urgent
              fontFamily: root.fontFamily
              bordered: true
              enabled: !root.pinBusy
              onClicked: removePin()
            }

            Button {
              width: parent.width
              text: strings.t("pin.cancel")
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: {
                root.pinSetupOpen = false
                clearPinFields()
                root.clearPinError()
              }
            }
          }
        }
      }
    }
  }

  component SecretField: Row {
    id: secret
    property alias text: field.text
    property alias placeholderText: field.placeholderText
    property alias inputMethodHints: field.inputMethodHints
    property alias validator: field.validator
    property alias field: field
    signal accepted()
    signal textEdited()

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(4)

    TextField {
      id: field
      width: Math.max(0, secret.width - showButton.width - secret.spacing)
      password: !root.showSecrets
      foreground: root.foreground
      onAccepted: secret.accepted()
      onTextChanged: secret.textEdited()
      Keys.onEscapePressed: root.close()
    }

    Button {
      id: showButton
      width: implicitWidth
      height: implicitHeight
      text: root.showSecrets ? strings.t("panel.hide") : strings.t("panel.show")
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      horizontalPadding: Style.spacing.controlPaddingX
      verticalPadding: Style.spacing.controlPaddingY
      bordered: true
      onClicked: root.showSecrets = !root.showSecrets
    }
  }

  component ItemRow: CursorSurface {
    id: itemRow
    property var item: null
    property int rowIndex: 0
    readonly property string itemName: item ? String(item.name || "") : ""
    readonly property string itemUser: item ? String(item.username || "") : ""
    readonly property bool favorite: item ? item.favorite === true : false
    readonly property bool hasTotp: item ? item.hasTotp === true : false
    readonly property string itemUrl: Model.safeUrl(item)

    hasCursor: root.cursorActive && root.itemIndex === rowIndex
    foreground: root.foreground
    implicitHeight: Math.max(itemText.implicitHeight, itemActions.implicitHeight) + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.itemIndex = itemRow.rowIndex
      }
      onClicked: {
        root.copyPasswordFor(itemRow.item)
        root.focusList()
      }
    }

    Row {
      id: itemText
      anchors.left: parent.left
      anchors.right: itemActions.left
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: itemRow.favorite ? "󰓎" : "󰌆"
        color: itemRow.favorite ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        width: Style.space(20)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: Math.max(0, parent.width - Style.space(20) - parent.spacing)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: itemRow.itemName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: itemRow.favorite
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: text !== ""
          text: itemRow.itemUser
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    Row {
      id: itemActions
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      PanelActionButton {
        iconText: "󰀄"
        tooltipText: strings.t("panel.copyUsername")
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: itemRow.itemUser !== "" && !root.busy
        onClicked: {
          root.copyUsernameFor(itemRow.item)
          root.focusList()
        }
      }

      PanelActionButton {
        iconText: "󰌆"
        tooltipText: strings.t("panel.copyPassword")
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !root.busy
        onClicked: {
          root.copyPasswordFor(itemRow.item)
          root.focusList()
        }
      }

      PanelActionButton {
        visible: itemRow.hasTotp
        iconText: "󰅐"
        tooltipText: strings.t("panel.copyTotp")
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !root.busy
        onClicked: {
          root.copyTotpFor(itemRow.item)
          root.focusList()
        }
      }

      PanelActionButton {
        visible: itemRow.itemUrl !== ""
        iconText: "󰏌"
        tooltipText: strings.t("panel.openUrl")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: {
          root.openUrlFor(itemRow.item)
          root.focusList()
        }
      }
    }
  }
}
