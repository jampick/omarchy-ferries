# Providers

A provider is one directory here with an executable `fetch` in it. The widget
never talks to a ferry operator directly: `bin/ferries-fetch` runs
`providers/<id>/fetch` and hands whatever it prints to the panel. The panel
renders that document and nothing else, so adding a region means adding a
directory and never touching the QML.

```
providers/
  README.md          this file
  wsdot/             Washington State Ferries
    fetch            python3, standard library only
    provider.json    static metadata: terminals, timezone, web links
```

## Contract

`fetch` is called as:

```
providers/<id>/fetch --route "<departing> - <arriving>" [--key KEY] [--now EPOCH] [--cache-dir DIR]
```

- `--route` is whatever the user typed into the `route` setting. Resolve it
  generously (ids, abbreviations, names, unique prefixes). If it does not
  resolve, say so in `error` and still fill `routes` so the picker works.
- `--key` is the `apiKey` setting, possibly empty. Providers that need one
  should also look in the environment and a file of their own, so the key
  does not have to sit in `shell.json`.
- `--now` overrides the clock for tests. `--cache-dir` overrides where cached
  responses go (default `$XDG_CACHE_HOME/omarchy-ferries/<id>/`).

It prints **one JSON document** to stdout and exits 0 when the document is
usable, non-zero otherwise. Print a document even on failure: the panel reads
`error` from it. Never let a traceback be the output.

Every list has a maximum length and every string a maximum length. The
document ends up inside a long-running shell process that owns the whole bar;
an upstream response, hostile or merely broken, must not be able to grow it.
`bin/ferries-run` caps the total at 256 KiB as a backstop, and the panel
re-caps on intake, but the provider is the layer that knows what "too many"
means for each list.

## Document

```jsonc
{
  "schema": 1,
  "provider": "wsdot",
  "providerName": "Washington State Ferries",
  "generatedAt": 1787950800,             // epoch seconds
  "timezone": "America/Los_Angeles",     // the operator's zone; labels below are in it
  "ok": true,                            // false when there is no sailing list
  "error": "",                           // "no api key" | "api key rejected" | "unknown route: ..." | "offline: ..." | free text
  "errors": [],                          // non-fatal, for the footer

  "route": {
    "id": 5, "abbrev": "sea-bi", "name": "Seattle / Bainbridge",
    "from": { "id": 3, "name": "Bainbridge Island", "abbrev": "BBI", "lat": 47.62, "lon": -122.51 },
    "to":   { "id": 7, "name": "Seattle",           "abbrev": "P52", "lat": 47.60, "lon": -122.34 },
    "notes": "",                         // sailing notes for this terminal pair
    "annotations": [],
    "links": {                           // https only; the panel refuses anything else
      "schedule": "...", "schedulePdf": "...", "map": "...", "alerts": "...", "terminal": "...", "cameras": "..."
    }
  },

  "departures": [                        // today, all of it, sorted, max 64
    {
      "time": 1787952300, "timeLabel": "2:25 PM",
      "arrival": 1787954400, "arrivalLabel": "3:00 PM",
      "vessel": "Wenatchee", "vesselId": 38, "fromId": 3,
      "status": "scheduled",             // scheduled | at-dock | inbound | late | departed | cancelled
      "delayMin": null,                  // estimate; the panel recomputes "still at dock" live
      "basis": "",                       // where delayMin came from: "still at dock", "inbound ETA 2:34 PM", "left dock", "operator"
      "cancelled": false,
      "spaceKnown": true,                // false means the operator did not publish a count. NOT zero.
      "driveUp": 84, "maxSpace": 144,
      "showReservable": false, "reservable": null,
      "annotations": ["Wait for second boat"],
      "crossingSec": 2100,               // nominal crossing, for projections
      "estimated": true,                 // projections differ from the timetable
      "estimateSource": "vesselwatch",   // "vesselwatch" | "clock" | ""
      "estimatedDeparture": 1787952420, "estimatedDepartureLabel": "2:27 PM",
      "estimatedArrival": 1787954520, "estimatedArrivalLabel": "3:02 PM"
    }
  ],

  "vessels": [                           // boats on this route, max 16
    {
      "id": 38, "name": "Wenatchee", "lat": 47.61, "lon": -122.42, "speed": 16.4, "heading": 95,
      "atDock": false, "inService": true,
      "fromId": 7, "from": "Seattle", "toId": 3, "to": "Bainbridge Island",
      "eta": 1787952840, "etaLabel": "2:34 PM", "etaBasis": "",
      "leftDock": 1787950080, "leftDockLabel": "1:48 PM",
      "scheduledDeparture": 1787949900, "scheduledDepartureLabel": "1:45 PM",
      "delayMin": 3,                     // leftDock minus scheduledDeparture
      "notice": "", "updated": 1787950780
    }
  ],

  "alerts":    [ { "id": 1, "title": "...", "text": "...", "type": "Delay", "published": 0, "publishedLabel": "1:50 PM", "allRoutes": false } ],  // max 20, newest first
  "bulletins": [ { "title": "...", "text": "...", "updated": 0, "updatedLabel": "" } ],   // terminal notices, max 10
  "waitTimes": [ { "routeId": 5, "route": "...", "notes": "...", "updated": 0, "updatedLabel": "" } ],  // max 6
  "cameras":   [ { "id": 9040, "title": "WSF Bainbridge Ferry Holding", "url": "https://...jpg", "lat": 0, "lon": 0, "terminalId": 3 } ],  // max 8, https only
  "routes":    [ { "fromId": 3, "from": "Bainbridge Island", "toId": 7, "to": "Seattle", "label": "Bainbridge Island → Seattle" } ],  // every pair the operator sails, max 80
  "links":     { "home": "...", "alerts": "...", "map": "...", "schedule": "...", "apiRegistration": "..." }
}
```

### What the panel does with it

- **Bar label**: countdown to the first departure that is not past and not
  cancelled. `late` and `at-dock` are never past, so a boat that is late at
  the dock stays "next" and the label turns into `+8m`.
- **Hero**: route title, next and following sailing, the next one's status or
  drive-up count as a pill.
- **Departures**: the next N (setting), or the whole day on `f`. Status text
  comes from `status` + `delayMin` + `basis`; space from `driveUp`/`maxSpace`.
- **On the water**: a schematic map drawn from `route.from`, `route.to` and
  each vessel's `lat`/`lon`/`heading`, plus one row per vessel.
- **Terminal**: `waitTimes` then `bulletins`.
- **Camera**: `cameras` in order; only `https://` URLs on hosts allowed by
  `bin/ferries-camera` are ever fetched. Add hosts there for a new operator.
- **Alerts**: `alerts` in order, expandable.
- **Route picker**: `routes`, written back to the `route` setting as
  `"<from> - <to>"`.

### Lateness

`status` is the provider's call, because only the provider sees the raw
vessel feed. The WSDOT provider's rules are in `classify()` in
`wsdot/fetch`, with tests in `test/wsdot.test.py`. The short version: a boat
that is at the dock past its scheduled time is late by the clock; a boat that
is inbound with an ETA later than the departure minus a minimum turnaround is
going to be late by that much; a boat that has left is departed; everything
else is what the operator scheduled. `basis` says which rule fired, because a
number without provenance invites more trust than it has earned.

## Adding a provider

1. Create `providers/<id>/fetch` (any language that is on a stock Omarchy
   install; bash and python3 are safe bets) and make it executable.
2. Emit the document above. Time labels in the operator's local zone;
   epochs in UTC seconds.
3. Cap everything. Read responses with a byte limit. Use a cache directory
   with per-endpoint TTLs and serve stale data when the network is down.
4. Add the operator's camera image hosts to `bin/ferries-camera` if it has
   cameras.
5. Add `<id>` to the `provider` enum in `manifest.json`.
6. Add tests under `test/` that run offline. `test/wsdot.test.py` is the
   pattern: build fixtures in the operator's shapes, point `fetch` at them
   with `--fixtures`, assert on the document.

Nothing else changes.
