#!/usr/bin/env python3
"""Verify local Toolkit reads against isolated projects and the Aides task store."""

from datetime import datetime, timedelta, timezone
from pathlib import Path
import argparse
import runpy
import sys
import tempfile


SMOKE = runpy.run_path(str(Path(__file__).with_name("test-server.py")))
Client = SMOKE["Client"]
IsolatedServer = SMOKE["IsolatedServer"]
SmokeFailure = SMOKE["SmokeFailure"]
find = SMOKE["find"]
require = SMOKE["require"]
wait_for_task = SMOKE["wait_for_task"]


def exercise(server):
    invite = server.invite()
    anonymous = server.start()
    actions = "/toolkit/local/actions"
    query = "/toolkit/local/query"
    anonymous.request("GET", actions, status=401)
    anonymous.post(query, {"action": "memory.search"}, status=401)
    owner = anonymous.post("/pair", {"code": invite, "name": "Toolkit local smoke"})
    client = Client(server.port, owner["token"])
    advertised = client.request("GET", actions)["actions"]
    require({item["id"] for item in advertised} == {
        "memory.search", "projects.list", "projects.files.list", "projects.files.read",
        "schedules.list", "notifications.list",
    }, "Unexpected local tool catalog")

    first = find(client.post("/projects", {"name": "Fixture A"})["projects"], name="Fixture A")
    snapshot = client.post("/projects", {"name": "Fixture B"})
    second = find(snapshot["projects"], name="Fixture B")
    thread = find(snapshot["threads"], projectID=first["id"])
    root = Path(first["directory"])
    (root / "Readme.txt").write_text("é" * 5_000, encoding="utf-8")
    (root / ".env").write_text("protected fixture", encoding="utf-8")
    (root / "Link.txt").symlink_to(Path(second["directory"]) / "Other.txt")
    (Path(second["directory"]) / "Other.txt").write_text("fixture outside grant", encoding="utf-8")

    client.post(query, {"action": "projects.files.list"}, status=403)
    request = {"action": "projects.files.list", "projectID": first["id"]}
    items = client.post(query, request)["items"]
    require([item["id"] for item in items] == ["Readme.txt"], "Listing exposed a protected or linked item")
    client.post(query, {**request, "path": "../"}, status=400)
    client.post(query, {**request, "threadID": thread["id"], "projectID": second["id"]}, status=409)
    read = {**request, "action": "projects.files.read"}
    client.post(query, {**read, "path": ".env"}, status=400)
    client.post(query, {**read, "path": "Link.txt"}, status=422)
    result = client.post(query, {**read, "path": "Readme.txt"})["items"][0]["detail"]
    require(result.endswith("…") and "\ufffd" not in result and len(result.encode()) <= 8_192,
            "Truncated file text was oversized or invalid UTF-8")
    print("PASS local Toolkit project grants, file boundaries, and bounded results")

    for project, key in [(first, "inside scope"), (second, "outside scope")]:
        client.post("/memory", {
            "key": key, "value": "scope fixture", "scope": "project:" + project["id"].lower(),
            "sensitivity": "localOnly",
        })
    request = {"action": "memory.search", "threadID": thread["id"], "query": "scope fixture"}
    require([item["title"] for item in client.post(query, request)["items"]] == ["inside scope"],
            "Toolkit memory search disregarded the selected project")
    client.post(query, {**request, "limit": 21}, status=400)

    schedule = {"title": "Toolkit schedule", "kind": "reminder", "repeatRule": "once",
                "timeZone": "UTC", "firstRun": (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()}
    client.post("/schedules", {**schedule, "threadID": thread["id"]})
    result = client.post(query, {"action": "schedules.list", "projectID": second["id"]})
    require(not result["items"], "A schedule appeared in a different project")
    result = client.post(query, {"action": "schedules.list", "threadID": thread["id"]})
    require(result["items"][0]["title"] == schedule["title"], "Toolkit did not show the existing schedule")
    output = client.post("/tasks", {"title": "Toolkit notification", "kind": "reminder", "threadID": thread["id"]})
    task = find(output["tasks"], title="Toolkit notification")
    wait_for_task(client, task["id"], "completed")
    result = client.post(query, {"action": "notifications.list", "threadID": thread["id"]})
    require(result["items"][0]["id"] == task["id"], "Toolkit did not show the completed reminder")
    print("PASS local Toolkit scoped memory, schedules, and reminder notifications")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="aides-toolkit-local-") as directory:
        server = IsolatedServer(args.binary.resolve(), Path(directory).resolve())
        try:
            exercise(server)
        except (SmokeFailure, OSError, ValueError) as error:
            print(f"FAIL local Toolkit smoke check ({type(error).__name__}): {error}", file=sys.stderr)
            return 1
        finally:
            server.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
