import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Ferries bar widget: one icon with a countdown, one panel.
//
// Built on the same bones as the first-party Network and Tailscale panels and
// the Proton VPN widget: a BarIconButton anchoring a KeyboardPanel, a
// single-cursor navigation model shared by mouse and keyboard, and
// CursorSurface for every highlightable row.
//
// Everything rendered here comes from one normalized document produced by a
// provider script (see providers/README.md). The panel does not know which
// ferry system it is looking at, which is what makes another one a drop-in.
Panel {
  id: root
  moduleName: "jampick.ferries"
  ipcTarget: "jampick.ferries"
  manageIpc: false

  Service {
    id: ferries
    settings: root.settings
    panelOpen: root.opened
    cameraWanted: root.opened && root.cameraOn && !root.pickerOpen
  }

  // --- Theme ------------------------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color faint: Qt.darker(foreground, 2.2)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  function severityColor(severity) {
    if (severity === "bad") return urgent
    if (severity === "warn") return foreground
    if (severity === "dim") return dim
    return foreground
  }

  // --- Derived state ----------------------------------------------------------
  readonly property var doc: ferries.doc
  readonly property real now: ferries.now
  readonly property bool hasData: !!doc && doc.ok === true
  readonly property string icon: Model.ferryIcon()
  readonly property string barText: Model.barLabel(doc, now, ferries.barLabelMode)
  readonly property string barSeverity: Model.barSeverity(doc, now)

  readonly property color barIconColor: {
    if (barSeverity === "bad") return bar ? bar.urgent : Color.urgent
    if (barSeverity === "dim") return Qt.darker(barForeground, 1.55)
    return barForeground
  }

  property bool fullDay: false
  property bool cameraOn: ferries.showCamera
  property bool pickerOpen: false
  property string routeQuery: ""
  property int expandedAlert: -1
  property int expandedTerminal: -1
  property int expandedDeparture: -1
  property string keyMessage: ""
  property bool keyMessageUrgent: false

  function saveKey() {
    var text = keyField.text.trim()
    if (text === "") { keyMessage = "Nothing to save yet."; keyMessageUrgent = true; return }
    if (!ferries.persistApiKey(text)) { keyMessage = "That does not look like an access code (no spaces or quotes)."; keyMessageUrgent = true; return }
    keyField.text = ""
    keyMessage = "Saved. Fetching today's sailings…"
    keyMessageUrgent = false
    keyCatcher.forceActiveFocus()
  }

  readonly property var departureRows: Model.departureRows(doc, now, ferries.departuresShown, fullDay)
  readonly property var vesselRows: Model.vesselRows(doc, now)
  readonly property var alertRows: Model.alertRows(doc)
  readonly property var terminalRows: Model.terminalRows(doc)
  readonly property var routeList: pickerOpen && doc
    ? Model.routeRows(doc.routes, routeQuery, doc.route && doc.route.from ? doc.route.from.id : -1, doc.route && doc.route.to ? doc.route.to.id : -1)
    : []
  readonly property var freshness: Model.freshness(doc, now, root.opened ? ferries.panelRefreshIntervalSec : ferries.refreshIntervalSec)

  readonly property string heroTitle: doc && doc.route ? Model.routeTitle(doc.route) : "Ferries"
  readonly property string heroMeta: {
    if (ferries.lastError !== "" && !doc) return ferries.lastError.toUpperCase()
    return Model.heroMeta(doc, now, ferries.loading)
  }
  readonly property string heroDetail: hasData ? Model.heroDetail(doc, now) : ""
  readonly property bool nextIsBad: hasData && Model.barSeverity(doc, now) === "bad"

  readonly property bool needsKey: !!doc && !doc.ok && doc.error === "no api key"
  readonly property bool badRoute: !!doc && !doc.ok && /^unknown route/i.test(doc.error)

  // Toolbar pills. Each has a key so the row and the keyboard shortcuts agree.
  readonly property var actions: {
    var list = []
    list.push({ id: "fullday", label: fullDay ? "Next only" : "Full day", key: "f", hint: "Toggle the whole day's schedule (f)" })
    list.push({ id: "schedule", label: "Schedule", key: "w", hint: "Open the printable schedule in the browser (w)" })
    list.push({ id: "map", label: "Map", key: "m", hint: "Open VesselWatch in the browser (m)" })
    list.push({ id: "alerts", label: "Alerts", key: "a", hint: "Open the route alerts page (a)" })
    if (ferries.showCamera) list.push({ id: "camera", label: cameraOn ? "Hide cam" : "Camera", key: "c", hint: "Show or hide the terminal camera (c)" })
    list.push({ id: "route", label: "Route", key: "/", hint: "Pick a different route (/)" })
    return list
  }

  // --- Cursor -----------------------------------------------------------------
  // Exactly one highlighted spot across the whole panel, addressed by
  // focusSection plus that section's index. Mouse hover and keyboard nav both
  // write this state at the root; no row ever reads containsMouse for visuals.
  property string focusSection: "header"
  property int actionIndex: 0
  property int alertIndex: 0
  property int departureIndex: 0
  property int vesselIndex: 0
  property int terminalIndex: 0
  property int routeIndex: 0
  property bool cursorActive: false

  readonly property bool headerHasCursor: cursorActive && focusSection === "header"

  readonly property bool hasActions: hasData || needsKey || badRoute
  readonly property bool hasAlerts: !pickerOpen && alertRows.length > 0
  readonly property bool hasDepartures: !pickerOpen && departureRows.length > 0
  readonly property bool hasVessels: !pickerOpen && vesselRows.length > 0
  readonly property bool hasTerminal: !pickerOpen && terminalRows.length > 0
  readonly property bool hasCamera: !pickerOpen && cameraOn && ferries.showCamera && ferries.cameraCount > 0
  readonly property bool hasRoutes: pickerOpen && routeList.length > 0

  function sectionOrder() {
    var order = ["header"]
    if (hasActions) order.push("actions")
    if (hasRoutes) order.push("routes")
    if (hasAlerts) order.push("alerts")
    if (hasDepartures) order.push("departures")
    if (hasVessels) order.push("vessels")
    if (hasTerminal) order.push("terminal")
    if (hasCamera) order.push("camera")
    return order
  }

  function rowsIn(section) {
    if (section === "alerts") return alertRows.length
    if (section === "departures") return departureRows.length
    if (section === "vessels") return vesselRows.length
    if (section === "terminal") return terminalRows.length
    if (section === "routes") return routeList.length
    return 1
  }

  function indexIn(section) {
    if (section === "alerts") return alertIndex
    if (section === "departures") return departureIndex
    if (section === "vessels") return vesselIndex
    if (section === "terminal") return terminalIndex
    if (section === "routes") return routeIndex
    return 0
  }

  function setIndexIn(section, value) {
    if (section === "alerts") alertIndex = value
    else if (section === "departures") departureIndex = value
    else if (section === "vessels") vesselIndex = value
    else if (section === "terminal") terminalIndex = value
    else if (section === "routes") routeIndex = value
  }

  function moveCursor(dx, dy) {
    if (dx !== 0) {
      if (focusSection === "actions") actionIndex = Math.max(0, Math.min(actions.length - 1, actionIndex + dx))
      else if (focusSection === "camera") ferries.stepCamera(dx)
      return
    }
    if (dy === 0) return

    var order = sectionOrder()
    var at = order.indexOf(focusSection)
    if (at === -1) { focusSection = order[0]; return }

    var next = indexIn(focusSection) + dy
    if (next >= 0 && next < rowsIn(focusSection)) {
      setIndexIn(focusSection, next)
      return
    }

    var target = at + (dy > 0 ? 1 : -1)
    if (target < 0 || target >= order.length) return

    focusSection = order[target]
    setIndexIn(focusSection, dy > 0 ? 0 : Math.max(0, rowsIn(focusSection) - 1))
  }

  function activateCursor() {
    if (focusSection === "header") { ferries.swapDirection(); return }
    if (focusSection === "actions") { runAction(actions[actionIndex]); return }
    if (focusSection === "alerts") { expandedAlert = expandedAlert === alertIndex ? -1 : alertIndex; return }
    if (focusSection === "departures") { expandedDeparture = expandedDeparture === departureIndex ? -1 : departureIndex; return }
    if (focusSection === "vessels") { ferries.openLink(ferries.link("map")); return }
    if (focusSection === "terminal") { expandedTerminal = expandedTerminal === terminalIndex ? -1 : terminalIndex; return }
    if (focusSection === "camera") { ferries.stepCamera(1); return }
    if (focusSection === "routes") { pickRoute(routeList[routeIndex]); return }
  }

  function focusRow(section, index) {
    cursorActive = true
    focusSection = section
    setIndexIn(section, index)
  }

  // The panel is taller than its window on a busy day, and keyboard cursor
  // movement does not scroll a Flickable by itself. Rows call this when they
  // take the cursor; a row already on screen leaves the scroll alone, so
  // mouse hover (which also moves the cursor) never yanks the view.
  function ensureVisible(item) {
    if (!item || !panelFlick) return
    var top = item.mapToItem(column, 0, 0).y
    var bottom = top + item.height
    var margin = Style.space(8)
    if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
    else if (bottom > panelFlick.contentY + panelFlick.height - margin)
      panelFlick.contentY = Math.min(Math.max(0, panelFlick.contentHeight - panelFlick.height), bottom - panelFlick.height + margin)
  }

  function runAction(action) {
    if (!action) return
    if (action.id === "fullday") fullDay = !fullDay
    else if (action.id === "schedule") ferries.openLink(ferries.link("schedulePdf") || ferries.link("schedule"))
    else if (action.id === "map") ferries.openLink(ferries.link("map"))
    else if (action.id === "alerts") ferries.openLink(ferries.link("alerts"))
    else if (action.id === "camera") cameraOn = !cameraOn
    else if (action.id === "route") togglePicker()
  }

  function togglePicker() {
    pickerOpen = !pickerOpen
    routeQuery = ""
    routeIndex = 0
    if (pickerOpen) Qt.callLater(function() { routeSearch.forceActiveFocus() })
    else keyCatcher.forceActiveFocus()
  }

  function pickRoute(row) {
    if (!row) return
    ferries.persistRoute(Model.routeSetting(row))
    pickerOpen = false
    routeQuery = ""
    keyCatcher.forceActiveFocus()
  }

  function handleKey(t) {
    if (t === "r" || t === "R") ferries.refresh()
    else if (t === "s" || t === "S") ferries.swapDirection()
    else if (t === "f" || t === "F") fullDay = !fullDay
    else if (t === "w" || t === "W") ferries.openLink(ferries.link("schedulePdf") || ferries.link("schedule"))
    else if (t === "m" || t === "M") ferries.openLink(ferries.link("map"))
    else if (t === "a" || t === "A") ferries.openLink(ferries.link("alerts"))
    else if (t === "c" || t === "C") { if (ferries.showCamera) cameraOn = !cameraOn }
    else if (t === "n" || t === "N") ferries.stepCamera(1)
    else if (t === "/") { if (!pickerOpen) togglePicker(); else routeSearch.forceActiveFocus() }
  }

  // --- Lifecycle --------------------------------------------------------------

  onOpenedChanged: {
    if (opened) {
      focusSection = "header"
      actionIndex = 0
      alertIndex = 0
      departureIndex = 0
      vesselIndex = 0
      terminalIndex = 0
      cursorActive = false
      expandedAlert = -1
      expandedTerminal = -1
      expandedDeparture = -1
    } else {
      pickerOpen = false
      routeQuery = ""
    }
  }

  // Sections come and go as documents land. Evacuate a cursor left pointing
  // at nothing rather than highlight thin air.
  onDepartureRowsChanged: {
    if (departureIndex >= departureRows.length) departureIndex = Math.max(0, departureRows.length - 1)
    if (expandedDeparture >= departureRows.length) expandedDeparture = -1
  }
  onAlertRowsChanged: if (alertIndex >= alertRows.length) alertIndex = Math.max(0, alertRows.length - 1)
  onVesselRowsChanged: if (vesselIndex >= vesselRows.length) vesselIndex = Math.max(0, vesselRows.length - 1)
  onTerminalRowsChanged: if (terminalIndex >= terminalRows.length) terminalIndex = Math.max(0, terminalRows.length - 1)
  onRouteListChanged: if (routeIndex >= routeList.length) routeIndex = Math.max(0, routeList.length - 1)
  onActionsChanged: if (actionIndex >= actions.length) actionIndex = Math.max(0, actions.length - 1)
  onPickerOpenChanged: { focusSection = pickerOpen ? "routes" : "header"; cursorActive = pickerOpen }

  IpcHandler {
    target: "jampick.ferries"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { ferries.refresh(); return "ok" }
    function swap(): string { ferries.swapDirection(); return "ok" }
    function route(value: string): string { ferries.persistRoute(value); return "ok" }
    function status(): string { return Model.tooltip(root.doc, root.now) }
  }

  // --- Bar button -------------------------------------------------------------

  // The bar sizes each slot from its widget's implicit size, and the base
  // Panel is a bare Item with no size of its own, so the button's size has to
  // be forwarded up here or the slot collapses to zero width.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText !== "" ? root.icon + " " + root.barText : root.icon
    fontFamily: root.fontFamily
    foreground: root.barIconColor
    tooltipText: root.opened ? "" : Model.tooltip(root.doc, root.now)

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) ferries.swapDirection()
      else if (buttonCode === Qt.MiddleButton) ferries.refresh()
      else root.toggle()
    }
  }

  // --- Panel ------------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: routeSearch.activeFocus || keyField.activeFocus

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: { if (root.pickerOpen) root.togglePicker(); else root.close() }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.handleKey(t) }

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

          // --- Hero -------------------------------------------------------------
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.headerHasCursor
            onRingVisibleChanged: if (ringVisible) root.ensureVisible(this)
            function focusHero() { root.focusRow("header", 0) }

            PanelHero {
              id: hero
              width: parent.width
              title: root.heroTitle
              meta: root.heroMeta
              detail: root.heroDetail
              foreground: root.nextIsBad ? root.urgent : root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.hasData ? 1.0 : 0.5

              iconComponent: Component {
                Text {
                  text: root.icon
                  color: root.nextIsBad ? root.urgent : (root.hasData ? root.foreground : root.dim)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              trailingControl: Component {
                PanelActionButton {
                  id: swapButton
                  visible: root.hasData
                  iconText: "󰓡"  // nf-md-swap_horizontal
                  tooltipText: "Swap direction (s)"
                  hasCursor: header.ringVisible
                  bordered: true
                  foreground: hero.foreground
                  fontFamily: root.fontFamily
                  onHovered: function(on) { if (on) header.focusHero() }
                  onClicked: ferries.swapDirection()
                }
              }
            }
          }

          // --- Setup banners ----------------------------------------------------
          // First-run setup. The code can be typed straight in here; it is
          // saved through `omarchy bar set`, the same place the settings UI
          // writes, so nothing about this widget's storage is special.
          CursorSurface {
            visible: root.needsKey
            width: parent.width
            implicitHeight: keyColumn.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground
            bordered: true

            Column {
              id: keyColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.rightMargin: Style.spacing.rowPaddingX
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                width: parent.width
                text: "This provider needs a free WSDOT API access code. Register an email at wsdot.wa.gov/traffic/api (the code is emailed), then paste it here."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Row {
                width: parent.width
                spacing: Style.space(6)

                TextField {
                  id: keyField
                  width: parent.width - saveKeyButton.implicitWidth - parent.spacing
                  placeholderText: "Paste the access code…"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  Keys.onReturnPressed: function(event) { root.saveKey(); event.accepted = true }
                  Keys.onEscapePressed: function(event) { keyCatcher.forceActiveFocus(); event.accepted = true }
                }

                Button {
                  id: saveKeyButton
                  text: "Save"
                  tooltipText: "Runs omarchy bar set jampick.ferries apiKey …"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  bordered: true
                  anchors.verticalCenter: parent.verticalCenter
                  onClicked: root.saveKey()
                }
              }

              Text {
                visible: root.keyMessage !== ""
                width: parent.width
                text: root.keyMessage
                textFormat: Text.PlainText
                color: root.keyMessageUrgent ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Button {
                text: "Get an access code"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                onClicked: ferries.openLink(root.doc && root.doc.links ? root.doc.links.apiRegistration : "")
              }
            }
          }

          NoticeRow {
            visible: root.badRoute
            urgentTone: false
            body: "The route setting did not match two terminals. Pick one from the list, or set it as \"Departing terminal - Arriving terminal\"."
            buttonLabel: "Pick a route"
            onActivated: root.togglePicker()
          }

          NoticeRow {
            visible: !!root.doc && !root.doc.ok && !root.needsKey && !root.badRoute
            urgentTone: true
            body: root.doc ? (root.doc.error === "api key rejected"
              ? "WSDOT rejected the access code. Check for a typo, or register a new one."
              : "The provider could not get today's sailings. " + (root.doc.error || "")) : ""
            buttonLabel: root.doc && root.doc.error === "api key rejected" ? "Register again" : "Retry"
            onActivated: {
              if (root.doc && root.doc.error === "api key rejected") ferries.openLink(root.doc.links ? root.doc.links.apiRegistration : "")
              else ferries.refresh()
            }
          }

          Text {
            visible: ferries.lastError !== "" && !!root.doc
            width: parent.width
            text: ferries.lastError
            textFormat: Text.PlainText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // --- Actions ----------------------------------------------------------
          Row {
            id: actionRow
            visible: root.hasActions
            width: parent.width
            spacing: Style.space(6)

            readonly property int count: Math.max(1, root.actions.length)
            readonly property real cellWidth: (width - spacing * (count - 1)) / count

            Repeater {
              model: root.actions

              delegate: Item {
                required property var modelData
                required property int index
                width: actionRow.cellWidth
                height: actionPill.implicitHeight

                ActionPill {
                  id: actionPill
                  action: modelData
                  slot: index
                  width: parent.width
                }
              }
            }
          }

          // --- Route picker -----------------------------------------------------
          Column {
            visible: root.pickerOpen
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.foreground }

            Item {
              width: parent.width
              implicitHeight: Math.max(routeHeader.implicitHeight, routeSearch.implicitHeight)

              PanelSectionHeader {
                id: routeHeader
                text: root.doc && root.doc.routes.length === 0 ? "NO ROUTES LISTED YET" : "ROUTES"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              TextField {
                id: routeSearch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(190)
                placeholderText: "Filter terminals…"
                text: root.routeQuery
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall

                onTextChanged: { root.routeQuery = text; root.routeIndex = 0 }

                Keys.onEscapePressed: function(event) {
                  if (text !== "") text = ""
                  else root.togglePicker()
                  event.accepted = true
                }
                Keys.onDownPressed: function(event) {
                  root.focusRow("routes", 0)
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
                Keys.onReturnPressed: function(event) {
                  if (root.routeList.length > 0) root.pickRoute(root.routeList[0])
                  event.accepted = true
                }
              }
            }

            ListView {
              id: routeListView
              visible: root.hasRoutes
              width: parent.width
              height: Math.min(contentHeight, Style.space(300))
              spacing: Style.space(2)
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              model: root.routeList
              currentIndex: root.focusSection === "routes" ? root.routeIndex : -1
              onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

              delegate: Item {
                required property var modelData
                required property int index
                width: ListView.view.width
                height: routeRow.implicitHeight

                RouteRow {
                  id: routeRow
                  row: modelData
                  slot: index
                  width: parent.width
                }
              }
            }

            Text {
              visible: root.pickerOpen && root.doc && root.doc.routes.length > 0 && root.routeList.length === 0
              width: parent.width
              text: "No route matches \"" + root.routeQuery + "\""
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          // --- Alerts -----------------------------------------------------------
          PanelSeparator { visible: root.hasAlerts; foreground: root.foreground }

          Column {
            visible: root.hasAlerts
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "ALERTS · " + root.alertRows.length
              foreground: root.urgent
              fontFamily: root.fontFamily
              bottomPadding: Style.space(4)
            }

            Repeater {
              model: root.alertRows

              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: alertRow.implicitHeight

                ExpandableRow {
                  id: alertRow
                  section: "alerts"
                  slot: index
                  title: modelData.title
                  body: modelData.text
                  meta: modelData.when
                  tone: root.urgent
                  expanded: root.expandedAlert === index
                  width: parent.width
                  onToggled: root.expandedAlert = root.expandedAlert === index ? -1 : index
                }
              }
            }
          }

          // --- Departures -------------------------------------------------------
          PanelSeparator { visible: root.hasDepartures; foreground: root.foreground }

          Column {
            visible: root.hasDepartures
            width: parent.width
            spacing: Style.space(4)

            Item {
              width: parent.width
              implicitHeight: depHeader.implicitHeight

              PanelSectionHeader {
                id: depHeader
                text: root.fullDay ? "TODAY · " + root.departureRows.length + " SAILINGS" : "NEXT SAILINGS"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "DRIVE-UP SPACE"
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Repeater {
              model: root.departureRows

              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: depRow.implicitHeight

                DepartureRow {
                  id: depRow
                  row: modelData
                  slot: index
                  width: parent.width
                }
              }
            }

            Text {
              visible: root.doc && root.doc.route && root.doc.route.notes ? root.doc.route.notes !== "" : false
              width: parent.width
              text: root.doc && root.doc.route ? String(root.doc.route.notes || "") : ""
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              topPadding: Style.space(4)
            }
          }

          Text {
            visible: root.hasData && !root.hasDepartures && !root.pickerOpen
            width: parent.width
            text: "No more sailings today. Press f for the full day, or w for the season schedule."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // --- On the water -----------------------------------------------------
          PanelSeparator { visible: root.hasVessels; foreground: root.foreground }

          Column {
            visible: root.hasVessels
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "ON THE WATER"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            RouteMap {
              width: parent.width
              height: Style.space(120)
            }

            Repeater {
              model: root.vesselRows

              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: vesselRow.implicitHeight

                VesselRow {
                  id: vesselRow
                  row: modelData
                  slot: index
                  width: parent.width
                }
              }
            }
          }

          // --- Terminal ---------------------------------------------------------
          PanelSeparator { visible: root.hasTerminal; foreground: root.foreground }

          Column {
            visible: root.hasTerminal
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "AT " + (root.doc && root.doc.route && root.doc.route.from ? String(root.doc.route.from.name || "").toUpperCase() : "THE TERMINAL")
              foreground: root.foreground
              fontFamily: root.fontFamily
              bottomPadding: Style.space(4)
            }

            Repeater {
              model: root.terminalRows

              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: termRow.implicitHeight

                ExpandableRow {
                  id: termRow
                  section: "terminal"
                  slot: index
                  title: modelData.title
                  body: modelData.text
                  meta: modelData.when
                  tone: root.foreground
                  expanded: root.expandedTerminal === index || modelData.kind === "wait"
                  width: parent.width
                  onToggled: root.expandedTerminal = root.expandedTerminal === index ? -1 : index
                }
              }
            }
          }

          // --- Camera -----------------------------------------------------------
          PanelSeparator { visible: root.hasCamera; foreground: root.foreground }

          Column {
            visible: root.hasCamera
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: camHeader.implicitHeight

              PanelSectionHeader {
                id: camHeader
                text: "CAMERA · " + (ferries.cameraTitle || "").toUpperCase()
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.right: camCount.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
              }

              Text {
                id: camCount
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: (ferries.cameraIndex + 1) + "/" + ferries.cameraCount
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            CursorSurface {
              id: cameraSurface
              width: parent.width
              implicitHeight: cameraImage.status === Image.Ready ? Math.round(width * Math.min(0.75, Math.max(0.5, cameraImage.sourceSize.height / Math.max(1, cameraImage.sourceSize.width)))) : Style.space(80)
              hasCursor: root.cursorActive && root.focusSection === "camera"
              onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
              foreground: root.foreground
              fill: root.hoverFill
              currentFill: root.selectedFill
              clip: true

              Image {
                id: cameraImage
                anchors.fill: parent
                anchors.margins: Style.space(2)
                source: ferries.cameraFile !== "" ? "file://" + ferries.cameraFile + "?" + ferries.cameraStamp : ""
                cache: false
                asynchronous: true
                fillMode: Image.PreserveAspectFit
                sourceSize.width: 800
                smooth: true
              }

              Text {
                anchors.centerIn: parent
                visible: cameraImage.status !== Image.Ready
                text: ferries.cameraBusy || ferries.cameraFile === "" ? "Loading camera…" : "Camera unavailable"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onContainsMouseChanged: if (containsMouse) root.focusRow("camera", 0)
                onClicked: function(mouse) {
                  root.focusRow("camera", 0)
                  if (mouse.button === Qt.RightButton) ferries.openLink(ferries.link("cameras"))
                  else ferries.stepCamera(1)
                }
              }

              PanelToolTip {
                visible: cameraSurface.hasCursor && ferries.cameraCount > 1
                text: "Click or n for the next camera · right click opens all of them"
                fontFamily: root.fontFamily
              }
            }
          }

          // --- Footer -----------------------------------------------------------
          Item {
            width: parent.width
            implicitHeight: footerText.implicitHeight
            visible: !!root.doc

            Text {
              id: footerText
              anchors.left: parent.left
              anchors.right: parent.right
              text: {
                var parts = []
                if (root.doc && root.doc.providerName) parts.push(String(root.doc.providerName))
                if (root.freshness.label) parts.push(root.freshness.label + (root.freshness.stale ? " · STALE" : ""))
                if (ferries.fetching) parts.push("refreshing…")
                return parts.join(" · ")
              }
              textFormat: Text.PlainText
              color: root.freshness.stale ? root.urgent : root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }

  // --- Components ---------------------------------------------------------------

  // Setup and failure banners. Bordered like the Proton widget's, with one
  // button that does the one thing that helps.
  component NoticeRow: CursorSurface {
    id: notice
    property string body: ""
    property string buttonLabel: ""
    property bool urgentTone: false
    signal activated()

    width: parent ? parent.width : implicitWidth
    implicitHeight: noticeColumn.implicitHeight + Style.spacing.rowPaddingX
    foreground: urgentTone ? root.urgent : root.foreground
    bordered: true

    Column {
      id: noticeColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        width: parent.width
        text: notice.body
        textFormat: Text.PlainText
        color: notice.urgentTone ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Button {
        visible: notice.buttonLabel !== ""
        text: notice.buttonLabel
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        bordered: true
        onClicked: notice.activated()
      }
    }
  }

  component ActionPill: Button {
    id: pill
    required property var action
    required property int slot

    text: action ? action.label : ""
    tooltipText: action ? action.hint : ""
    fontSize: Style.font.bodySmall
    foreground: root.foreground
    fontFamily: root.fontFamily
    horizontalPadding: Style.space(4)
    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
    bordered: true
    active: action ? (action.id === "fullday" && root.fullDay) || (action.id === "route" && root.pickerOpen) || (action.id === "camera" && root.cameraOn) : false
    hasCursor: root.cursorActive && root.focusSection === "actions" && root.actionIndex === slot
    onHasCursorChanged: if (hasCursor) root.ensureVisible(this)

    onClicked: root.runAction(action)
    onHovered: function(isHovered) { if (isHovered) root.focusRow("actions", pill.slot) }
  }

  // One sailing. Time and boat on the left, status in the middle, drive-up
  // space with a small bar on the right. Enter expands the row to show
  // annotations and where the lateness estimate came from.
  component DepartureRow: CursorSurface {
    id: depItem
    required property var row
    required property int slot

    readonly property bool isSelected: root.focusSection === "departures" && root.departureIndex === slot
    readonly property bool expanded: root.expandedDeparture === slot
    readonly property color tone: row ? (row.past ? root.faint : root.severityColor(row.severity)) : root.foreground
    readonly property var space: row ? row.space : ({ label: "--", ratio: -1, severity: "dim", known: false })

    hasCursor: root.cursorActive && isSelected
    current: row ? row.isNext : false
    onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: depBody.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.focusRow("departures", depItem.slot)
      onClicked: {
        root.focusRow("departures", depItem.slot)
        root.expandedDeparture = depItem.expanded ? -1 : depItem.slot
      }
    }

    Column {
      id: depBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Item {
        width: parent.width
        implicitHeight: Math.max(depTime.implicitHeight, depSpace.implicitHeight)

        Text {
          id: depTime
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(70)
          text: depItem.row ? depItem.row.timeLabel : ""
          textFormat: Text.PlainText
          color: depItem.row && depItem.row.past ? root.faint : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: depItem.row ? depItem.row.isNext : false
          font.strikeout: depItem.row ? depItem.row.cancelled : false
        }

        Column {
          anchors.left: depTime.right
          anchors.right: depSpace.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            width: parent.width
            text: depItem.row ? depItem.row.vessel : ""
            textFormat: Text.PlainText
            color: depItem.row && depItem.row.past ? root.faint : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            visible: text !== ""
            text: {
              if (!depItem.row) return ""
              if (depItem.row.status !== "") return depItem.row.status
              return depItem.row.past ? "" : depItem.row.countdown
            }
            textFormat: Text.PlainText
            color: depItem.row && depItem.row.status !== "" ? depItem.tone : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: depItem.row ? depItem.row.severity === "bad" : false
            elide: Text.ElideRight
          }
        }

        Column {
          id: depSpace
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(84)
          spacing: Style.space(3)

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignRight
            text: depItem.space.label
            textFormat: Text.PlainText
            color: depItem.row && depItem.row.past ? root.faint : root.severityColor(depItem.space.severity)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: depItem.space.severity === "bad"
          }

          Rectangle {
            width: parent.width
            height: Style.space(3)
            radius: height / 2
            visible: depItem.space.ratio >= 0
            color: Util.alpha(root.foreground, 0.12)

            Rectangle {
              width: parent.width * Math.max(0.02, depItem.space.ratio)
              height: parent.height
              radius: height / 2
              color: root.severityColor(depItem.space.severity)
              opacity: depItem.row && depItem.row.past ? 0.3 : 1
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignRight
            visible: depItem.space.reservable !== null && depItem.space.reservable !== undefined
            text: depItem.space.reservable !== null && depItem.space.reservable !== undefined ? depItem.space.reservable + " reservable" : ""
            textFormat: Text.PlainText
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        visible: depItem.expanded && text !== ""
        width: parent.width
        text: {
          if (!depItem.row) return ""
          var parts = []
          if (depItem.row.arrivalLabel) parts.push("Arrives " + depItem.row.arrivalLabel)
          if (depItem.row.basis && depItem.row.status !== "") parts.push("Basis: " + depItem.row.basis)
          for (var i = 0; i < depItem.row.annotations.length; i++) parts.push(depItem.row.annotations[i])
          return parts.join(" · ")
        }
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  component VesselRow: CursorSurface {
    id: vesselItem
    required property var row
    required property int slot

    readonly property bool isSelected: root.focusSection === "vessels" && root.vesselIndex === slot

    hasCursor: root.cursorActive && isSelected
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: vesselBody.implicitHeight + Style.spacing.rowPaddingX
    onHasCursorChanged: if (hasCursor) root.ensureVisible(this)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.focusRow("vessels", vesselItem.slot)
      onClicked: { root.focusRow("vessels", vesselItem.slot); ferries.openLink(ferries.link("map")) }
    }

    Item {
      id: vesselBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(vesselName.implicitHeight, vesselDetail.implicitHeight)

      Text {
        id: vesselGlyph
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: vesselItem.row && vesselItem.row.atDock ? "󰀱" : "󰈓"   // nf-md-anchor / nf-md-ferry
        color: vesselItem.row && vesselItem.row.late ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        id: vesselName
        anchors.left: vesselGlyph.right
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: (vesselItem.row ? vesselItem.row.name : "") + "  " + (vesselItem.row ? vesselItem.row.where : "")
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        width: Math.min(implicitWidth, parent.width - vesselGlyph.width - vesselDetail.implicitWidth - Style.space(24))
      }

      Text {
        id: vesselDetail
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: {
          if (!vesselItem.row) return ""
          var parts = []
          if (vesselItem.row.detail) parts.push(vesselItem.row.detail)
          if (vesselItem.row.late) parts.push("+" + vesselItem.row.delayMin + " min")
          return parts.join(" · ")
        }
        textFormat: Text.PlainText
        color: vesselItem.row && vesselItem.row.late ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }

  // Alerts and terminal bulletins: a title line, expandable to the body.
  component ExpandableRow: CursorSurface {
    id: expItem
    required property string section
    required property int slot
    property string title: ""
    property string body: ""
    property string meta: ""
    property color tone: root.foreground
    property bool expanded: false
    signal toggled()

    readonly property bool isSelected: root.focusSection === section && root.indexIn(section) === slot

    hasCursor: root.cursorActive && isSelected
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: expBody.implicitHeight + Style.spacing.rowPaddingX
    onHasCursorChanged: if (hasCursor) root.ensureVisible(this)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: expItem.body !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.focusRow(expItem.section, expItem.slot)
      onClicked: { root.focusRow(expItem.section, expItem.slot); expItem.toggled() }
    }

    Column {
      id: expBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Item {
        width: parent.width
        implicitHeight: expTitle.implicitHeight

        Text {
          id: expTitle
          anchors.left: parent.left
          anchors.right: expMeta.left
          anchors.rightMargin: Style.space(8)
          text: expItem.title
          textFormat: Text.PlainText
          color: expItem.tone
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: expItem.expanded ? Text.ElideNone : Text.ElideRight
          wrapMode: expItem.expanded ? Text.WordWrap : Text.NoWrap
          maximumLineCount: expItem.expanded ? 6 : 1
        }

        Text {
          id: expMeta
          anchors.right: parent.right
          anchors.top: parent.top
          text: expItem.meta
          textFormat: Text.PlainText
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Text {
        visible: expItem.expanded && expItem.body !== ""
        width: parent.width
        text: expItem.body
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        maximumLineCount: 14
        elide: Text.ElideRight
      }
    }
  }

  component RouteRow: CursorSurface {
    id: routeItem
    required property var row
    required property int slot

    readonly property bool isSelected: root.focusSection === "routes" && root.routeIndex === slot

    hasCursor: root.cursorActive && isSelected
    current: row ? row.current : false
    onHasCursorChanged: if (hasCursor) root.ensureVisible(this)
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: routeLabel.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.focusRow("routes", routeItem.slot)
      onClicked: { root.focusRow("routes", routeItem.slot); root.pickRoute(routeItem.row) }
    }

    Text {
      id: routeLabel
      anchors.left: parent.left
      anchors.right: routeState.left
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: routeItem.row ? routeItem.row.label : ""
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Text {
      id: routeState
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      text: routeItem.row && routeItem.row.current ? "Current" : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // Schematic crossing: the two terminals, a dotted line between them, and
  // every boat on the route as an arrow pointing where it is headed. No
  // tiles and no network: a crossing of a few miles is a straight line, and
  // "which side of the water is my boat on" is the whole question.
  component RouteMap: Canvas {
    id: mapCanvas
    readonly property var points: Model.mapLayout(root.doc ? root.doc.route : null, root.doc ? root.doc.vessels : [], width, height, Style.space(26))

    onPointsChanged: requestPaint()
    onWidthChanged: requestPaint()
    Connections { target: root; function onForegroundChanged() { mapCanvas.requestPaint() } }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: ferries.openLink(ferries.link("map"))
      PanelToolTip {
        visible: parent.containsMouse
        text: "Open VesselWatch (m)"
        fontFamily: root.fontFamily
      }
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width, h = height
      var fg = root.foreground

      ctx.fillStyle = Util.alpha(fg, 0.05)
      ctx.strokeStyle = Util.alpha(fg, 0.15)
      ctx.lineWidth = 1
      roundRect(ctx, 0.5, 0.5, w - 1, h - 1, Style.cornerRadius)
      ctx.fill()
      ctx.stroke()

      var pts = mapCanvas.points
      if (!pts || pts.length < 2) return
      var from = pts[0], to = pts[1]

      // Crossing line.
      if (ctx.setLineDash) ctx.setLineDash([3, 5])
      ctx.strokeStyle = Util.alpha(fg, 0.35)
      ctx.lineWidth = 1.5
      ctx.beginPath()
      ctx.moveTo(from.x, from.y)
      ctx.lineTo(to.x, to.y)
      ctx.stroke()
      if (ctx.setLineDash) ctx.setLineDash([])

      ctx.font = "bold " + Style.font.caption + "px " + root.fontFamily
      ctx.textBaseline = "middle"

      // Terminals.
      for (var t = 0; t < 2; t++) {
        var p = pts[t]
        ctx.fillStyle = p.isFrom ? fg : Util.alpha(fg, 0.55)
        ctx.beginPath()
        ctx.arc(p.x, p.y, 4, 0, Math.PI * 2)
        ctx.fill()
        var label = String(p.label || "").toUpperCase()
        var labelW = ctx.measureText(label).width
        var leftSide = p.x < w / 2
        var lx = leftSide ? p.x + 9 : p.x - 9 - labelW
        lx = Math.max(4, Math.min(w - labelW - 4, lx))
        var ly = p.y < h / 2 ? p.y + 12 : p.y - 12
        ctx.fillStyle = p.isFrom ? fg : Util.alpha(fg, 0.7)
        ctx.fillText(label, lx, ly)
      }

      // Boats: a triangle pointing along the heading, name beside it.
      ctx.font = Style.font.caption + "px " + root.fontFamily
      for (var i = 2; i < pts.length; i++) {
        var v = pts[i]
        var colour = v.late ? root.urgent : fg
        ctx.save()
        ctx.translate(v.x, v.y)
        ctx.rotate((Number(v.heading) || 0) * Math.PI / 180)
        ctx.fillStyle = colour
        ctx.beginPath()
        if (v.atDock) {
          ctx.rect(-4, -4, 8, 8)
        } else {
          ctx.moveTo(0, -7)
          ctx.lineTo(5, 6)
          ctx.lineTo(0, 3)
          ctx.lineTo(-5, 6)
          ctx.closePath()
        }
        ctx.fill()
        ctx.restore()

        var name = String(v.label || "")
        var nameW = ctx.measureText(name).width
        var nx = v.x + 9
        if (nx + nameW > w - 4) nx = v.x - 9 - nameW
        var ny = v.y - 9
        if (ny < 8) ny = v.y + 10
        ctx.fillStyle = Util.alpha(colour, 0.9)
        ctx.fillText(name, nx, ny)
      }
    }

    function roundRect(ctx, x, y, w, h, r) {
      var radius = Math.max(0, Math.min(r, Math.min(w, h) / 2))
      ctx.beginPath()
      ctx.moveTo(x + radius, y)
      ctx.lineTo(x + w - radius, y)
      ctx.quadraticCurveTo(x + w, y, x + w, y + radius)
      ctx.lineTo(x + w, y + h - radius)
      ctx.quadraticCurveTo(x + w, y + h, x + w - radius, y + h)
      ctx.lineTo(x + radius, y + h)
      ctx.quadraticCurveTo(x, y + h, x, y + h - radius)
      ctx.lineTo(x, y + radius)
      ctx.quadraticCurveTo(x, y, x + radius, y)
      ctx.closePath()
    }
  }
}
