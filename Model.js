// Pure helpers for the Ferries panel.
//
// Side-effect free and Node-testable, the same split the first-party panels
// use. The QML side does process handling and rendering; everything that
// turns the provider's normalized document into rows, labels and colours
// lives here so it can be exercised without a compositor.
//
// The document shape is defined in providers/README.md. Nothing in this file
// knows which ferry system produced it.

var MAX_ITEMS = { departures: 64, vessels: 16, alerts: 20, bulletins: 10, waitTimes: 6, cameras: 8, routes: 80 }
var MAX_STRING = 600

// ---------------------------------------------------------------------------
// Document intake
// ---------------------------------------------------------------------------

// Strip control characters and cap length. Everything the panel renders from
// the document passes through here, and is then drawn with Text.PlainText,
// so operator-supplied text can neither reflow the panel nor reach Qt's
// rich-text parser.
function cleanString(value, limit) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "")
  var max = limit || MAX_STRING
  return text.length > max ? text.substring(0, max - 1) + "…" : text
}

function sanitize(value, depth) {
  var level = depth || 0
  if (level > 6) return null
  if (Array.isArray(value)) {
    var out = []
    for (var i = 0; i < value.length && i < 128; i++) out.push(sanitize(value[i], level + 1))
    return out
  }
  if (value && typeof value === "object") {
    var obj = {}
    var keys = Object.keys(value)
    for (var k = 0; k < keys.length && k < 64; k++) obj[keys[k]] = sanitize(value[keys[k]], level + 1)
    return obj
  }
  if (typeof value === "string") return cleanString(value)
  if (typeof value === "number") return isFinite(value) ? value : null
  return value
}

// Parse the provider's stdout. Returns null when it is not a document this
// panel understands, so the caller keeps the last good one.
function parseDoc(raw) {
  var parsed
  try { parsed = JSON.parse(String(raw || "")) } catch (e) { return null }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null
  if (parsed.schema !== 1) return null

  var doc = sanitize(parsed)
  var lists = Object.keys(MAX_ITEMS)
  for (var i = 0; i < lists.length; i++) {
    var name = lists[i]
    if (!Array.isArray(doc[name])) doc[name] = []
    else if (doc[name].length > MAX_ITEMS[name]) doc[name] = doc[name].slice(0, MAX_ITEMS[name])
  }
  if (!doc.route || typeof doc.route !== "object") doc.route = null
  if (!doc.links || typeof doc.links !== "object") doc.links = {}
  doc.ok = doc.ok === true
  doc.error = cleanString(doc.error, 200)
  doc.generatedAt = Number(doc.generatedAt) || 0
  return doc
}

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

function minutesBetween(from, to) {
  return Math.round((Number(to) - Number(from)) / 60)
}

// "now", "12 min", "1 h 05", "3 h"; negative deltas read "12 min ago".
function countdown(now, when) {
  var t = Number(when)
  if (!isFinite(t) || t <= 0) return ""
  var delta = t - Number(now)
  var ago = delta < 0
  var mins = Math.round(Math.abs(delta) / 60)
  var text
  if (Math.abs(delta) < 45) text = "now"
  else if (mins < 60) text = mins + " min"
  else if (mins < 600) {
    var h = Math.floor(mins / 60), m = mins % 60
    text = m === 0 ? h + " h" : h + " h " + (m < 10 ? "0" + m : m)
  } else text = Math.round(mins / 60) + " h"
  if (text === "now") return text
  return ago ? text + " ago" : text
}

// Compact form for the bar: "12m", "1h05", "3h", "now".
function shortCountdown(now, when) {
  var t = Number(when)
  if (!isFinite(t) || t <= 0) return ""
  var delta = t - Number(now)
  if (delta < 45 && delta > -600) return "now"
  if (delta < 0) return ""
  var mins = Math.round(delta / 60)
  if (mins < 60) return mins + "m"
  var h = Math.floor(mins / 60), m = mins % 60
  if (mins >= 600) return h + "h"
  return m === 0 ? h + "h" : h + "h" + (m < 10 ? "0" + m : m)
}

// ---------------------------------------------------------------------------
// Departures
// ---------------------------------------------------------------------------

var LATE_GRACE_SEC = 60

// A sailing is behind us once the boat has gone, or once its time has passed
// with nothing live saying it is still here. "late" and "at-dock" are never
// past: they are the boat, present, that has not left yet.
function isPast(dep, now) {
  if (!dep) return true
  if (dep.status === "departed") return true
  if (dep.status === "late" || dep.status === "at-dock") return false
  return Number(dep.time) < Number(now) - LATE_GRACE_SEC
}

function nextIndex(doc, now) {
  var list = doc && Array.isArray(doc.departures) ? doc.departures : []
  for (var i = 0; i < list.length; i++) {
    var dep = list[i]
    if (!dep || dep.cancelled || dep.status === "cancelled") continue
    if (!isPast(dep, now)) return i
  }
  return -1
}

function nextDeparture(doc, now) {
  var i = nextIndex(doc, now)
  return i === -1 ? null : doc.departures[i]
}

// The sailing after the next one, which is the other question people ask.
function followingDeparture(doc, now) {
  var list = doc && Array.isArray(doc.departures) ? doc.departures : []
  var i = nextIndex(doc, now)
  if (i === -1) return null
  for (var j = i + 1; j < list.length; j++) {
    var dep = list[j]
    if (!dep || dep.cancelled || dep.status === "cancelled") continue
    return dep
  }
  return null
}

// Live lateness. A boat still at the dock keeps getting later between
// fetches, so that case is recomputed from the clock; the others come from
// the provider with their basis attached.
function delayMinutes(dep, now) {
  if (!dep) return 0
  if (dep.status === "late" && /still at dock/i.test(String(dep.basis || ""))) {
    return Math.max(1, minutesBetween(dep.time, now))
  }
  var d = Number(dep.delayMin)
  return isFinite(d) ? d : 0
}

// {label, severity} for a sailing. Severity is one of ok, warn, bad, dim
// and maps onto the theme: bad is the urgent colour, dim is faded.
function statusInfo(dep, now) {
  if (!dep) return { label: "", severity: "dim" }
  var status = String(dep.status || "scheduled")
  if (dep.cancelled || status === "cancelled") return { label: "Cancelled", severity: "bad" }
  if (status === "late") {
    var late = delayMinutes(dep, now)
    return { label: "Late " + late + " min", severity: late >= 5 ? "bad" : "warn" }
  }
  if (status === "departed") {
    var d = delayMinutes(dep, now)
    return { label: d >= 2 ? "Left " + d + " min late" : "Departed", severity: "dim" }
  }
  if (status === "at-dock") return { label: "At dock", severity: "ok" }
  if (status === "inbound") return { label: "Inbound", severity: "ok" }
  if (isPast(dep, now)) return { label: "Departed", severity: "dim" }
  return { label: "", severity: "ok" }
}

// Drive-up car space. Unknown is "--", never zero: WSDOT only publishes
// counts for some departures and an absent number is not a full boat.
function spaceInfo(dep) {
  if (!dep || !dep.spaceKnown || dep.driveUp === null || dep.driveUp === undefined) {
    return { label: "--", ratio: -1, severity: "dim", known: false }
  }
  var count = Math.max(0, Number(dep.driveUp) || 0)
  var max = Number(dep.maxSpace) || 0
  var ratio = max > 0 ? Math.max(0, Math.min(1, count / max)) : -1
  var severity = "ok"
  if (count === 0) severity = "bad"
  else if (ratio >= 0 && ratio < 0.15) severity = "bad"
  else if (ratio >= 0 && ratio < 0.35) severity = "warn"
  else if (ratio < 0 && count < 20) severity = "warn"
  var label = count === 0 ? "Full" : count + (count === 1 ? " car" : " cars")
  return { label: label, ratio: ratio, severity: severity, known: true, reservable: dep.showReservable ? dep.reservable : null }
}

// Rows for the departures section. Normally the next `limit` sailings from
// the next one onward (cancelled ones included, so a gap is visible as a
// gap). Full-day mode is the whole schedule with past sailings dimmed.
function departureRows(doc, now, limit, fullDay) {
  var list = doc && Array.isArray(doc.departures) ? doc.departures : []
  var out = []
  var start = fullDay ? 0 : nextIndex(doc, now)
  if (start === -1) return out
  var cap = fullDay ? list.length : Math.max(1, Number(limit) || 4)
  for (var i = start; i < list.length && out.length < cap; i++) {
    var dep = list[i]
    if (!dep) continue
    var status = statusInfo(dep, now)
    out.push({
      time: dep.time,
      timeLabel: dep.timeLabel || "",
      arrivalLabel: dep.arrivalLabel || "",
      vessel: dep.vessel || "",
      countdown: countdown(now, dep.time),
      past: isPast(dep, now),
      cancelled: !!dep.cancelled || dep.status === "cancelled",
      isNext: !fullDay ? i === start : i === nextIndex(doc, now),
      status: status.label,
      severity: status.severity,
      basis: dep.basis || "",
      space: spaceInfo(dep),
      annotations: Array.isArray(dep.annotations) ? dep.annotations.slice(0, 4) : []
    })
  }
  return out
}

// ---------------------------------------------------------------------------
// Bar
// ---------------------------------------------------------------------------

function ferryIcon() { return "󰈓" }  // nf-md-ferry

// What sits beside the icon. Countdown mode shows minutes to the next
// sailing; once a boat is late at the dock it shows how late, prefixed "+",
// which is the number you actually want when you are standing in the lot.
function barLabel(doc, now, mode) {
  if (!doc || mode === "icon") return ""
  var dep = nextDeparture(doc, now)
  if (!dep) return ""
  if (mode === "time") return dep.timeLabel || ""
  if (dep.status === "late") {
    var late = delayMinutes(dep, now)
    if (Number(dep.time) <= Number(now)) return "+" + late + "m"
  }
  return shortCountdown(now, dep.time)
}

// ok, bad or dim. Bad is for the states that change what you do next:
// cancelled, or late by enough to matter. Alerts alone do not light the bar
// up; WSF posts many, and an icon that is always red means nothing.
function barSeverity(doc, now) {
  if (!doc || !doc.ok) return "dim"
  var dep = nextDeparture(doc, now)
  if (!dep) return "dim"
  var info = statusInfo(dep, now)
  if (info.severity === "bad") return "bad"
  // The very next sailing being cancelled is worth red even though
  // nextDeparture skips it: it is the sailing you were planning on.
  var list = doc.departures
  for (var i = 0; i < list.length; i++) {
    var d = list[i]
    if (!d || isPast(d, now)) continue
    if (d.cancelled || d.status === "cancelled") return "bad"
    break
  }
  return "ok"
}

function tooltip(doc, now) {
  if (!doc) return "Ferries"
  if (!doc.ok) return doc.error === "no api key" ? "Ferries · add a WSDOT API access code" : ("Ferries · " + (doc.error || "no data"))
  var dep = nextDeparture(doc, now)
  var route = doc.route ? routeTitle(doc.route) : ""
  if (!dep) return route + " · no more sailings today"
  var parts = [route, dep.timeLabel]
  if (dep.vessel) parts.push(dep.vessel)
  var info = statusInfo(dep, now)
  parts.push(info.label || countdown(now, dep.time))
  var space = spaceInfo(dep)
  if (space.known) parts.push(space.label === "Full" ? "no drive-up space" : space.label + " drive-up")
  return parts.join(" · ")
}

// ---------------------------------------------------------------------------
// Hero
// ---------------------------------------------------------------------------

function routeTitle(route) {
  if (!route) return "Ferries"
  var from = route.from && route.from.name ? route.from.name : ""
  var to = route.to && route.to.name ? route.to.name : ""
  if (from && to) return from + " → " + to
  return route.name || "Ferries"
}

function heroMeta(doc, now, loading) {
  if (!doc) return loading ? "LOADING…" : "NO DATA YET"
  if (!doc.ok) {
    if (doc.error === "no api key") return "NEEDS A WSDOT API ACCESS CODE"
    if (doc.error === "api key rejected") return "WSDOT REJECTED THE ACCESS CODE"
    if (/^unknown route/i.test(doc.error)) return "ROUTE NOT RECOGNISED"
    if (/^offline/i.test(doc.error)) return "OFFLINE · " + doc.error.replace(/^offline:\s*/i, "").toUpperCase()
    return (doc.error || "NO DATA").toUpperCase()
  }
  var dep = nextDeparture(doc, now)
  if (!dep) return "NO MORE SAILINGS TODAY"
  var parts = ["NEXT " + dep.timeLabel]
  if (dep.vessel) parts.push(dep.vessel.toUpperCase())
  var cd = countdown(now, dep.time)
  if (cd) parts.push(cd === "now" ? "NOW" : "IN " + cd.toUpperCase())
  var after = followingDeparture(doc, now)
  if (after) parts.push("THEN " + after.timeLabel)
  return parts.join(" · ")
}

function heroDetail(doc, now) {
  var dep = nextDeparture(doc, now)
  if (!dep) return ""
  var info = statusInfo(dep, now)
  if (info.label) return info.label.toUpperCase()
  var space = spaceInfo(dep)
  if (space.known) return space.label.toUpperCase()
  return "ON TIME"
}

// ---------------------------------------------------------------------------
// Vessels
// ---------------------------------------------------------------------------

function knots(speed) {
  var s = Number(speed)
  if (!isFinite(s) || s < 0.5) return ""
  return (Math.round(s * 10) / 10) + " kn"
}

function vesselRows(doc, now) {
  var list = doc && Array.isArray(doc.vessels) ? doc.vessels : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var v = list[i]
    if (!v) continue
    var late = isFinite(Number(v.delayMin)) && Number(v.delayMin) >= 5
    var where, detail
    if (v.atDock) {
      where = "At " + (v.from || "dock")
      detail = v.scheduledDepartureLabel ? "Leaves " + v.scheduledDepartureLabel : ""
    } else {
      where = "→ " + (v.to || "?")
      detail = v.etaLabel ? "ETA " + v.etaLabel : ""
      var spd = knots(v.speed)
      if (spd) detail = detail ? detail + " · " + spd : spd
    }
    if (!v.inService) { where = v.name ? "Out of service" : where }
    out.push({
      name: v.name || "Vessel",
      where: where,
      detail: detail,
      late: late,
      delayMin: late ? Number(v.delayMin) : 0,
      notice: v.notice || "",
      atDock: !!v.atDock,
      heading: Number(v.heading) || 0,
      lat: v.lat, lon: v.lon
    })
  }
  return out
}

// Schematic map: the two terminals and every vessel on the route, projected
// onto a w x h canvas. Equirectangular around the route midpoint is more
// than accurate enough for a crossing of a few miles, and needs no tiles,
// no network and no map library. Returns [] when there is nothing to draw.
function mapLayout(route, vessels, w, h, pad) {
  if (!route || !route.from || !route.to) return []
  var from = route.from, to = route.to
  if (!isFinite(Number(from.lat)) || !isFinite(Number(from.lon)) || !isFinite(Number(to.lat)) || !isFinite(Number(to.lon))) return []

  var midLat = (Number(from.lat) + Number(to.lat)) / 2
  var kx = Math.cos(midLat * Math.PI / 180)
  var points = [
    { kind: "terminal", label: from.name || "", lon: Number(from.lon), lat: Number(from.lat), isFrom: true },
    { kind: "terminal", label: to.name || "", lon: Number(to.lon), lat: Number(to.lat), isFrom: false }
  ]
  var list = Array.isArray(vessels) ? vessels : []
  for (var i = 0; i < list.length; i++) {
    var v = list[i]
    if (!v || !isFinite(Number(v.lat)) || !isFinite(Number(v.lon))) continue
    if (v.inService === false) continue
    points.push({ kind: "vessel", label: v.name || "", lon: Number(v.lon), lat: Number(v.lat), heading: Number(v.heading) || 0, atDock: !!v.atDock, late: isFinite(Number(v.delayMin)) && Number(v.delayMin) >= 5 })
  }

  // Fit the terminals with padding; vessels normally sit between them. A
  // vessel far outside the crossing (WSDOT tags a boat with a route while it
  // is still repositioning) is clamped to the edge rather than squashing the
  // whole crossing into a corner to fit it.
  var minLon = Math.min(from.lon, to.lon), maxLon = Math.max(from.lon, to.lon)
  var minLat = Math.min(from.lat, to.lat), maxLat = Math.max(from.lat, to.lat)
  var spanX = Math.max((maxLon - minLon) * kx, 0.002)
  var spanY = Math.max(maxLat - minLat, 0.002)
  var padding = Number(pad) || 16
  var scale = Math.min((w - padding * 2) / spanX, (h - padding * 2) / spanY)
  var cx = (minLon + maxLon) / 2, cy = (minLat + maxLat) / 2

  var out = []
  for (var p = 0; p < points.length; p++) {
    var pt = points[p]
    var x = w / 2 + (pt.lon - cx) * kx * scale
    var y = h / 2 - (pt.lat - cy) * scale
    pt.x = Math.max(padding / 2, Math.min(w - padding / 2, x))
    pt.y = Math.max(padding / 2, Math.min(h - padding / 2, y))
    pt.clamped = pt.x !== x || pt.y !== y
    out.push(pt)
  }
  return out
}

// ---------------------------------------------------------------------------
// Alerts, bulletins, wait times
// ---------------------------------------------------------------------------

function alertRows(doc) {
  var list = doc && Array.isArray(doc.alerts) ? doc.alerts : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var a = list[i]
    if (!a) continue
    out.push({
      id: a.id,
      title: a.title || "",
      text: a.text && a.text !== a.title ? a.text : "",
      when: a.publishedLabel || "",
      allRoutes: !!a.allRoutes
    })
  }
  return out
}

function terminalRows(doc) {
  var out = []
  var waits = doc && Array.isArray(doc.waitTimes) ? doc.waitTimes : []
  for (var i = 0; i < waits.length; i++) {
    var w = waits[i]
    if (!w || !w.notes) continue
    out.push({ kind: "wait", title: "Wait times" + (w.route ? " · " + w.route : ""), text: w.notes, when: w.updatedLabel || "" })
  }
  var bulletins = doc && Array.isArray(doc.bulletins) ? doc.bulletins : []
  for (var b = 0; b < bulletins.length; b++) {
    var bl = bulletins[b]
    if (!bl) continue
    out.push({ kind: "bulletin", title: bl.title || "", text: bl.text && bl.text !== bl.title ? bl.text : "", when: bl.updatedLabel || "" })
  }
  return out
}

// ---------------------------------------------------------------------------
// Route picker
// ---------------------------------------------------------------------------

function routeKey(fromId, toId) { return String(fromId) + ">" + String(toId) }

function routeRows(routes, query, currentFromId, currentToId) {
  var list = Array.isArray(routes) ? routes : []
  var needle = String(query || "").trim().toLowerCase()
  var current = routeKey(currentFromId, currentToId)
  var out = []
  for (var i = 0; i < list.length; i++) {
    var r = list[i]
    if (!r) continue
    var label = r.label || (r.from + " → " + r.to)
    if (needle !== "" && label.toLowerCase().indexOf(needle) === -1) continue
    out.push({ fromId: r.fromId, toId: r.toId, from: r.from, to: r.to, label: label, current: routeKey(r.fromId, r.toId) === current })
  }
  out.sort(function(a, b) {
    if (a.current !== b.current) return a.current ? -1 : 1
    return a.label.localeCompare(b.label)
  })
  return out
}

// The value written back to the `route` setting. Names, because that is what
// a person reads in the settings panel; the provider resolves them.
function routeSetting(row) {
  if (!row) return ""
  return String(row.from || "") + " - " + String(row.to || "")
}

function swappedRouteSetting(route) {
  if (!route || !route.from || !route.to) return ""
  return String(route.to.name || "") + " - " + String(route.from.name || "")
}

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

function elide(text, limit) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  var max = parseInt(limit, 10) || 140
  return value.length > max ? value.substring(0, max - 1) + "…" : value
}

// Age of the document, for the "updated" line. Past three refresh intervals
// the panel says so, because a countdown built on stale positions is wrong
// in a way that looks right.
function freshness(doc, now, intervalSec) {
  if (!doc || !doc.generatedAt) return { label: "", stale: true }
  var age = Number(now) - Number(doc.generatedAt)
  var stale = age > Math.max(90, Number(intervalSec) * 3)
  var label = age < 5 ? "just now" : age < 60 ? Math.round(age) + "s ago" : Math.round(age / 60) + " min ago"
  return { label: "Updated " + label, stale: stale, ageSec: age }
}

if (typeof module !== "undefined") {
  module.exports = {
    cleanString: cleanString,
    sanitize: sanitize,
    parseDoc: parseDoc,
    minutesBetween: minutesBetween,
    countdown: countdown,
    shortCountdown: shortCountdown,
    isPast: isPast,
    nextIndex: nextIndex,
    nextDeparture: nextDeparture,
    followingDeparture: followingDeparture,
    delayMinutes: delayMinutes,
    statusInfo: statusInfo,
    spaceInfo: spaceInfo,
    departureRows: departureRows,
    ferryIcon: ferryIcon,
    barLabel: barLabel,
    barSeverity: barSeverity,
    tooltip: tooltip,
    routeTitle: routeTitle,
    heroMeta: heroMeta,
    heroDetail: heroDetail,
    knots: knots,
    vesselRows: vesselRows,
    mapLayout: mapLayout,
    alertRows: alertRows,
    terminalRows: terminalRows,
    routeKey: routeKey,
    routeRows: routeRows,
    routeSetting: routeSetting,
    swappedRouteSetting: swappedRouteSetting,
    elide: elide,
    freshness: freshness
  }
}
