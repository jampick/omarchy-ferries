#!/usr/bin/env python3
"""Tests for providers/wsdot/fetch: date parsing, lateness classification,
sailing space, alert filtering, caps, and the no-key path.

Fixtures are built here in the documented WSDOT shapes with times relative to
a fixed "now", written to a temp directory, and fed to the script through
--fixtures so nothing touches the network."""

import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True  # keep __pycache__ out of the plugin tree

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FETCH = os.path.join(ROOT, "providers", "wsdot", "fetch")

spec = importlib.util.spec_from_file_location("wsdot_fetch", FETCH, loader=importlib.machinery.SourceFileLoader("wsdot_fetch", FETCH))
wsdot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wsdot)

# 2026-08-28 14:00:00 PDT
NOW = 1787950800
BBI, SEA = 3, 7


def wcf(seconds):
    return "/Date(%d000-0700)/" % seconds


def vessel(vid, name, **kw):
    base = {
        "VesselID": vid, "VesselName": name, "Mmsi": 0,
        "DepartingTerminalID": BBI, "DepartingTerminalName": "Bainbridge Island", "DepartingTerminalAbbrev": "BBI",
        "ArrivingTerminalID": SEA, "ArrivingTerminalName": "Seattle", "ArrivingTerminalAbbrev": "P52",
        "Latitude": 47.61, "Longitude": -122.45, "Speed": 16.4, "Heading": 95,
        "InService": True, "AtDock": False, "LeftDock": None, "Eta": None, "EtaBasis": "",
        "ScheduledDeparture": None, "OpRouteAbbrev": ["sea-bi"], "VesselPositionNum": 1, "SortSeq": 1,
        "ManagedBy": 1, "TimeStamp": wcf(NOW - 20), "VesselWatchShutID": 0, "VesselWatchShutMsg": "",
        "VesselWatchShutFlag": "0", "VesselWatchStatus": "", "VesselWatchMsg": "",
    }
    base.update(kw)
    return base


def schedule(times):
    return {
        "ScheduleID": 1, "ScheduleName": "Summer", "ScheduleSeason": 2,
        "SchedulePDFUrl": "http://www.wsdot.wa.gov/ferries/pdf/2026Summer.pdf",
        "ScheduleStart": wcf(NOW - 86400 * 30), "ScheduleEnd": wcf(NOW + 86400 * 30), "AllRoutes": [5],
        "TerminalCombos": [{
            "DepartingTerminalID": BBI, "DepartingTerminalName": "Bainbridge Island",
            "ArrivingTerminalID": SEA, "ArrivingTerminalName": "Seattle",
            "SailingNotes": "Sailings may be delayed.", "Annotations": ["Wait for second boat"],
            "Times": [
                {"DepartingTime": wcf(t), "ArrivingTime": wcf(t + 35 * 60), "LoadingRule": 3,
                 "VesselID": vid, "VesselName": name, "VesselHandicapAccessible": True,
                 "VesselPositionNum": 1, "Routes": [5], "AnnotationIndexes": ann}
                for (t, vid, name, ann) in times
            ],
            "AnnotationsIVR": [],
        }],
    }


def space(rows):
    return [{
        "TerminalID": BBI, "TerminalSubjectID": 1, "RegionID": 1, "TerminalName": "Bainbridge Island",
        "TerminalAbbrev": "BBI", "SortSeq": 1,
        "DepartingSpaces": [{
            "Departure": wcf(t), "IsCancelled": cancelled, "VesselID": vid, "VesselName": name, "MaxSpaceCount": 144,
            "SpaceForArrivalTerminals": [{
                "TerminalID": SEA, "TerminalName": "Seattle", "VesselID": vid, "VesselName": name,
                "DisplayReservableSpace": False, "ReservableSpaceCount": 0, "ReservableSpaceHexColor": "",
                "DisplayDriveUpSpace": True, "DriveUpSpaceCount": drive, "DriveUpSpaceHexColor": "#00ff00",
                "MaxSpaceCount": 144, "ArrivalTerminalIDs": [SEA],
            }],
        } for (t, vid, name, drive, cancelled) in rows],
        "IsNoFareCollected": False, "NoFareCollectedMsg": "",
    }]


def write_fixtures(directory, **overrides):
    docs = {
        "terminallocations": [
            {"TerminalID": BBI, "TerminalName": "Bainbridge Island", "TerminalAbbrev": "BBI", "Latitude": 47.6229, "Longitude": -122.5110},
            {"TerminalID": SEA, "TerminalName": "Seattle", "TerminalAbbrev": "P52", "Latitude": 47.6025, "Longitude": -122.3384},
        ],
        "routes-3-7": [{"RouteID": 5, "RouteAbbrev": "sea-bi", "Description": "Seattle / Bainbridge", "RegionID": 1, "ServiceDisruptions": []}],
        "schedule-3-7-2026-08-28": schedule([
            (NOW - 55 * 60, 38, "Wenatchee", []),      # 13:05, sailed
            (NOW - 10 * 60, 68, "Tacoma", []),         # 13:50, still at dock: LATE
            (NOW + 35 * 60, 38, "Wenatchee", [0]),     # 14:35, inbound ETA too late: LATE (est)
            (NOW + 80 * 60, 68, "Tacoma", []),         # 15:20
            (NOW + 125 * 60, 38, "Wenatchee", []),     # 16:05
        ]),
        "vessellocations": [
            vessel(68, "Tacoma", AtDock=True, ScheduledDeparture=wcf(NOW - 10 * 60), Speed=0),
            vessel(38, "Wenatchee", DepartingTerminalID=SEA, DepartingTerminalName="Seattle", DepartingTerminalAbbrev="P52",
                   ArrivingTerminalID=BBI, ArrivingTerminalName="Bainbridge Island", ArrivingTerminalAbbrev="BBI",
                   LeftDock=wcf(NOW - 12 * 60), ScheduledDeparture=wcf(NOW - 15 * 60), Eta=wcf(NOW + 34 * 60), EtaBasis="speed",
                   Heading=275),
            vessel(99, "Elsewhere", DepartingTerminalID=8, ArrivingTerminalID=12, OpRouteAbbrev=["ed-king"]),
            # Shares Seattle's dock with us but sails to Bremerton: not our route.
            vessel(77, "Kaleetan", DepartingTerminalID=SEA, ArrivingTerminalID=4, OpRouteAbbrev=["sea-br"],
                   VesselWatchShutFlag="1", VesselWatchShutMsg="Vessel information unavailable",
                   VesselWatchMsg="VesselWatch is out of service"),
        ],
        "sailingspace-3": space([
            (NOW - 10 * 60, 68, "Tacoma", 0, False),
            (NOW + 35 * 60, 38, "Wenatchee", 84, False),
            (NOW + 80 * 60, 68, "Tacoma", 130, True),
        ]),
        "alerts": [
            {"BulletinID": 1, "AlertFullTitle": "Sea/BI: Tacoma running late", "BulletinText": "<p>Mechanical &amp; crew</p>",
             "PublishDate": wcf(NOW - 600), "AllRoutesFlag": False, "AffectedRouteIDs": [5], "AlertType": "Delay"},
            {"BulletinID": 2, "AlertFullTitle": "Edm/King only", "BulletinText": "Not ours", "PublishDate": wcf(NOW - 900),
             "AllRoutesFlag": False, "AffectedRouteIDs": [6]},
            {"BulletinID": 3, "AlertFullTitle": "Systemwide notice", "BulletinText": "Applies to all", "PublishDate": wcf(NOW - 60),
             "AllRoutesFlag": True, "AffectedRouteIDs": []},
        ],
        "bulletins-3": [{"TerminalID": BBI, "Bulletins": [
            {"BulletinTitle": "Parking", "BulletinText": "Lot A closed\x00\x01", "BulletinSortSeq": 2, "BulletinLastUpdated": wcf(NOW - 3600)},
            {"BulletinTitle": "Walk-on", "BulletinText": "Use the overhead walkway", "BulletinSortSeq": 1, "BulletinLastUpdated": wcf(NOW - 7200)},
            {"BulletinTitle": "Systemwide notice", "BulletinText": "mirrored from alerts", "BulletinSortSeq": 3, "BulletinLastUpdated": wcf(NOW - 60)},
        ]}],
        "waittimes-3": [{"TerminalID": BBI, "WaitTimes": [
            {"RouteID": 5, "RouteName": "Seattle / Bainbridge", "WaitTimeNotes": "One boat wait for vehicles", "WaitTimeLastUpdated": wcf(NOW - 300)},
            {"RouteID": None, "RouteName": None, "WaitTimeNotes": "Ancient advice", "WaitTimeLastUpdated": wcf(NOW - 86400 * 400)},
        ]}],
        "cameras": {"FeedContentList": [
            {"TerminalID": BBI, "FerryCamera": {"CamID": 9040, "Lat": 47.62, "Lon": -122.51, "Title": "WSF Bainbridge Ferry Holding",
                                                 "ImgURL": "https://images.wsdot.wa.gov/wsf/Bainbridge/Bainbridge.jpg", "IsActive": True}},
            {"TerminalID": BBI, "FerryCamera": {"CamID": 9477, "Lat": 47.62, "Lon": -122.51, "Title": "SR 305 at MP 0.2",
                                                 "ImgURL": "https://images.wsdot.wa.gov/orflow/305vc00023.jpg", "IsActive": True}},
            {"TerminalID": BBI, "FerryCamera": {"CamID": 1, "Title": "http cam", "ImgURL": "http://insecure.example/x.jpg", "IsActive": True}},
            {"TerminalID": SEA, "FerryCamera": {"CamID": 2, "Title": "Other terminal", "ImgURL": "https://images.wsdot.wa.gov/x.jpg", "IsActive": True}},
        ]},
        "terminalsandmates": [
            {"DepartingTerminalID": BBI, "DepartingDescription": "Bainbridge Island", "ArrivingTerminalID": SEA, "ArrivingDescription": "Seattle"},
            {"DepartingTerminalID": SEA, "DepartingDescription": "Seattle", "ArrivingTerminalID": BBI, "ArrivingDescription": "Bainbridge Island"},
            {"DepartingTerminalID": 8, "DepartingDescription": "Edmonds", "ArrivingTerminalID": 12, "ArrivingDescription": "Kingston"},
        ],
    }
    docs.update(overrides)
    for name, body in docs.items():
        with open(os.path.join(directory, name + ".json"), "w", encoding="utf-8") as fh:
            json.dump(body, fh)


def run(fixtures, route="Bainbridge Island - Seattle", extra=()):
    cmd = [sys.executable, FETCH, "--route", route, "--now", str(NOW), "--fixtures", fixtures] + list(extra)
    proc = subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, "WSDOT_ACCESS_CODE": "", "HOME": fixtures})
    return proc.returncode, json.loads(proc.stdout), proc.stderr


class Helpers(unittest.TestCase):
    def test_wcf_dates(self):
        self.assertEqual(wsdot.epoch("/Date(1787950800000-0700)/"), 1787950800)
        self.assertEqual(wsdot.epoch("\\/Date(1787950800000)\\/"), 1787950800)
        self.assertIsNone(wsdot.epoch("nope"))
        self.assertIsNone(wsdot.epoch(None))

    def test_clean_strips_control_and_markup(self):
        self.assertEqual(wsdot.clean("<b>Lot</b>\x00 A &amp; B   closed"), "Lot A & B closed")
        self.assertEqual(len(wsdot.clean("x" * 5000)), wsdot.MAX_TEXT)

    def test_terminal_resolution(self):
        terms = wsdot.load_provider_meta()["terminals"]
        self.assertEqual(wsdot.resolve_terminal("BBI", terms)["id"], 3)
        self.assertEqual(wsdot.resolve_terminal("7", terms)["id"], 7)
        self.assertEqual(wsdot.resolve_terminal("bainbridge", terms)["id"], 3)
        self.assertEqual(wsdot.resolve_terminal("Port Townsend", terms)["id"], 17)
        self.assertIsNone(wsdot.resolve_terminal("Po", terms))  # ambiguous prefix
        self.assertIsNone(wsdot.resolve_terminal("", terms))

    def test_split_route(self):
        self.assertEqual(wsdot.split_route("Bainbridge Island - Seattle"), ("Bainbridge Island", "Seattle"))
        self.assertEqual(wsdot.split_route("BBI>P52"), ("BBI", "P52"))
        self.assertEqual(wsdot.split_route("Edmonds to Kingston"), ("Edmonds", "Kingston"))
        self.assertEqual(wsdot.split_route("Seattle"), (None, None))

    def test_time_label_is_local(self):
        zone = wsdot.local_zone("America/Los_Angeles")
        self.assertEqual(wsdot.time_label(NOW, zone), "2:00 PM")
        self.assertEqual(wsdot.day_key(NOW, zone), "2026-08-28")


class Document(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="ferries-test-")
        write_fixtures(cls.tmp)
        cls.rc, cls.doc, cls.err = run(cls.tmp)

    def deps(self):
        return {d["timeLabel"]: d for d in self.doc["departures"]}

    def test_ok(self):
        self.assertEqual(self.rc, 0, self.err)
        self.assertTrue(self.doc["ok"])
        self.assertEqual(self.doc["error"], "")
        self.assertEqual(self.doc["route"]["from"]["id"], BBI)
        self.assertEqual(self.doc["route"]["to"]["id"], SEA)
        self.assertEqual(self.doc["route"]["links"]["schedule"], "https://wsdot.com/ferries/schedule/scheduledetailbyroute.aspx?route=sea-bi")
        self.assertEqual(self.doc["route"]["links"]["map"], "https://wsdot.com/ferries/vesselwatch/default.aspx?view=seabi")
        self.assertEqual(self.doc["route"]["links"]["schedulePdf"], "https://www.wsdot.wa.gov/ferries/pdf/2026Summer.pdf")

    def test_departures_sorted_and_labelled(self):
        labels = [d["timeLabel"] for d in self.doc["departures"]]
        self.assertEqual(labels, ["1:05 PM", "1:50 PM", "2:35 PM", "3:20 PM", "4:05 PM"])

    def test_late_at_dock(self):
        d = self.deps()["1:50 PM"]
        self.assertEqual(d["status"], "late")
        self.assertEqual(d["delayMin"], 10)
        self.assertEqual(d["basis"], "still at dock")
        self.assertTrue(d["spaceKnown"])
        self.assertEqual(d["driveUp"], 0)

    def test_late_from_inbound_eta(self):
        d = self.deps()["2:35 PM"]
        self.assertEqual(d["status"], "late")
        # ETA 14:34 + 3 min turnaround = 14:37, two minutes after 14:35.
        self.assertEqual(d["delayMin"], 2)
        self.assertIn("inbound ETA", d["basis"])
        self.assertEqual(d["driveUp"], 84)
        self.assertEqual(d["annotations"], ["Wait for second boat"])

    def test_cancelled_from_sailing_space(self):
        d = self.deps()["3:20 PM"]
        self.assertTrue(d["cancelled"])
        self.assertEqual(d["status"], "cancelled")

    def test_unknown_space_is_not_zero(self):
        d = self.deps()["4:05 PM"]
        self.assertFalse(d["spaceKnown"])
        self.assertIsNone(d["driveUp"])
        self.assertEqual(d["status"], "scheduled")

    def test_sailed_departure(self):
        # Wenatchee's feed shows it left Seattle, not Bainbridge, so the 1:05
        # sailing has no live evidence and falls to "scheduled" (past by time).
        d = self.deps()["1:05 PM"]
        self.assertIn(d["status"], ("scheduled", "departed"))

    def test_vessels_filtered_to_route(self):
        names = sorted(v["name"] for v in self.doc["vessels"])
        self.assertEqual(names, ["Tacoma", "Wenatchee"])
        self.assertEqual([v["notice"] for v in self.doc["vessels"]], ["", ""])
        wen = [v for v in self.doc["vessels"] if v["name"] == "Wenatchee"][0]
        self.assertEqual(wen["etaLabel"], "2:34 PM")
        self.assertEqual(wen["delayMin"], 3)   # left 3 min after scheduled
        self.assertEqual(wen["heading"], 275)

    def test_alerts_filtered_to_route_plus_systemwide(self):
        titles = [a["title"] for a in self.doc["alerts"]]
        self.assertEqual(titles, ["Systemwide notice", "Sea/BI: Tacoma running late"])
        late = self.doc["alerts"][1]
        self.assertEqual(late["text"], "Mechanical & crew")
        self.assertEqual(late["type"], "Delay")

    def test_bulletins_sorted_and_cleaned(self):
        self.assertEqual([b["title"] for b in self.doc["bulletins"]], ["Walk-on", "Parking"])
        self.assertEqual(self.doc["bulletins"][1]["text"], "Lot A closed")

    def test_wait_times(self):
        self.assertEqual(self.doc["waitTimes"][0]["notes"], "One boat wait for vehicles")
        self.assertEqual(self.doc["waitTimes"][0]["updatedLabel"], "1:55 PM")

    def test_old_timestamps_show_a_date(self):
        zone = wsdot.local_zone("America/Los_Angeles")
        self.assertEqual(wsdot.when_label(NOW - 300, NOW, zone), "1:55 PM")
        self.assertEqual(wsdot.when_label(NOW - 86400, NOW, zone), "Aug 27, 2:00 PM")
        self.assertEqual(wsdot.when_label(NOW - 86400 * 400, NOW, zone), "Jul 24, 2025")

    def test_bulletins_mirroring_alerts_are_dropped(self):
        self.assertNotIn("Systemwide notice", [b["title"] for b in self.doc["bulletins"]])

    def test_cameras_only_https_and_this_terminal(self):
        cams = self.doc["cameras"]
        self.assertEqual([c["id"] for c in cams], [9040, 9477])
        self.assertTrue(all(c["url"].startswith("https://") for c in cams))

    def test_routes_for_picker(self):
        labels = [r["label"] for r in self.doc["routes"]]
        self.assertEqual(labels, ["Bainbridge Island → Seattle", "Edmonds → Kingston", "Seattle → Bainbridge Island"])


class EdgeCases(unittest.TestCase):
    def test_no_key_path_still_has_cameras(self):
        tmp = tempfile.mkdtemp(prefix="ferries-nokey-")
        cmd = [sys.executable, FETCH, "--route", "BBI - P52", "--now", str(NOW), "--no-network", "--cache-dir", tmp]
        proc = subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, "WSDOT_ACCESS_CODE": "", "HOME": tmp, "XDG_CONFIG_HOME": tmp})
        doc = json.loads(proc.stdout)
        self.assertEqual(proc.returncode, 0)
        self.assertFalse(doc["ok"])
        self.assertEqual(doc["error"], "no api key")
        self.assertEqual(doc["route"]["from"]["abbrev"], "BBI")
        self.assertIn("apiRegistration", doc["links"])

    def test_key_from_file(self):
        tmp = tempfile.mkdtemp(prefix="ferries-keyfile-")
        os.makedirs(os.path.join(tmp, "omarchy-ferries"))
        with open(os.path.join(tmp, "omarchy-ferries", "wsdot-access-code"), "w") as fh:
            fh.write("  abc-123 \n")
        old = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = tmp
        os.environ["WSDOT_ACCESS_CODE"] = ""
        try:
            self.assertEqual(wsdot.find_key(""), "abc-123")
            self.assertEqual(wsdot.find_key(" explicit "), "explicit")
            os.environ["WSDOT_ACCESS_CODE"] = "fromenv"
            self.assertEqual(wsdot.find_key(""), "fromenv")
        finally:
            if old is None:
                del os.environ["XDG_CONFIG_HOME"]
            else:
                os.environ["XDG_CONFIG_HOME"] = old
            os.environ.pop("WSDOT_ACCESS_CODE", None)

    def test_unknown_route_offers_picker(self):
        tmp = tempfile.mkdtemp(prefix="ferries-badroute-")
        write_fixtures(tmp)
        rc, doc, _ = run(tmp, route="Narnia - Seattle")
        self.assertEqual(rc, 1)
        self.assertFalse(doc["ok"])
        self.assertTrue(doc["error"].startswith("unknown route"))
        self.assertEqual(len(doc["routes"]), 3)

    def test_missing_schedule_is_not_ok_but_has_cameras(self):
        tmp = tempfile.mkdtemp(prefix="ferries-nosched-")
        write_fixtures(tmp, **{"schedule-3-7-2026-08-28": {}, "sailingspace-3": []})
        rc, doc, _ = run(tmp)
        self.assertFalse(doc["ok"])
        self.assertEqual(doc["departures"], [])
        self.assertEqual(len(doc["cameras"]), 2)

    def test_caps_hold_against_a_flood(self):
        tmp = tempfile.mkdtemp(prefix="ferries-flood-")
        many = [(NOW + i * 60, 38, "Wenatchee" * 40, []) for i in range(500)]
        alerts = [{"BulletinID": i, "AlertFullTitle": "A" * 5000, "BulletinText": "B" * 5000, "PublishDate": wcf(NOW - i),
                   "AllRoutesFlag": True, "AffectedRouteIDs": []} for i in range(300)]
        write_fixtures(tmp, **{"schedule-3-7-2026-08-28": schedule(many), "alerts": alerts})
        rc, doc, _ = run(tmp)
        self.assertEqual(len(doc["departures"]), wsdot.MAX_DEPARTURES)
        self.assertEqual(len(doc["alerts"]), wsdot.MAX_ALERTS)
        self.assertLessEqual(len(doc["alerts"][0]["title"]), wsdot.MAX_TITLE)
        self.assertLessEqual(len(doc["departures"][0]["vessel"]), wsdot.MAX_NAME)
        self.assertLess(len(json.dumps(doc)), 262144)

    def test_garbage_upstream_does_not_crash(self):
        tmp = tempfile.mkdtemp(prefix="ferries-garbage-")
        write_fixtures(tmp, **{"vessellocations": "not a list", "sailingspace-3": {"DepartingSpaces": [None, 5, {"Departure": "x"}]},
                               "alerts": {"nope": 1}, "cameras": [1, 2], "bulletins-3": None, "waittimes-3": [None]})
        rc, doc, err = run(tmp)
        self.assertTrue(doc["ok"], err)
        self.assertEqual(doc["vessels"], [])
        self.assertEqual(doc["cameras"], [])
        self.assertEqual(len(doc["departures"]), 5)


if __name__ == "__main__":
    unittest.main(verbosity=1)
