#!/usr/bin/env python3
"""Exercise Toolkit command approval and receipts on an isolated server."""

import json
import runpy
import sys
import tempfile
import uuid
from pathlib import Path

fixtures = runpy.run_path(str(Path(__file__).with_name("test-server.py")))
Client = fixtures["Client"]
IsolatedServer = fixtures["IsolatedServer"]
find = fixtures["find"]
require = fixtures["require"]
wait_for = fixtures["wait_for"]


def exercise(server):
    invite = server.invite()
    anonymous = server.start()
    owner = anonymous.post("/pair", {"code": invite, "name": "Command smoke owner"})
    client = Client(server.port, owner["token"])
    state = client.post("/projects", {"name": "Command project"})
    project = find(state["projects"], name="Command project")
    account = {
        "id": "fixture", "label": "Print fixture", "projectID": project["id"],
        "executable": "/bin/echo", "arguments": ["literal-fixture"], "timeoutSeconds": 5,
    }
    server.stop()
    profiles = [
        account, {**account, "id": "stop", "executable": "/bin/sleep", "arguments": ["20"], "timeoutSeconds": 25},
        {**account, "id": "child", "executable": "/bin/sh", "arguments": ["-c", "sleep 20 & exit 0"], "timeoutSeconds": 12},
    ]
    directory = server.data / "Toolkit"
    directory.mkdir(mode=0o700)
    config = directory / "commands.json"
    config.write_text(json.dumps(profiles))
    config.chmod(0o600)
    server.start()

    base = "/toolkit/commands"
    anonymous.request("GET", base, status=401)
    catalog = client.request("GET", base)
    require(len(catalog) == 3 and catalog[0]["arguments"] == ["literal-fixture"],
            "Command preview did not show the exact arguments")
    request = {"id": str(uuid.uuid4()).upper(), "approved": False, "revision": catalog[0]["revision"]}
    client.post(base + "/fixture/run", request, status=403)
    require(not client.request("GET", base + "/runs"), "Unconfirmed command created a receipt")
    request["approved"] = True
    stale = [{**account, "arguments": ["different operation"]}, *profiles[1:]]
    config.write_text(json.dumps(stale))
    client.post(base + "/fixture/run", request, status=409)
    require(not client.request("GET", base + "/runs"), "A stale command review started different arguments")
    config.write_text(json.dumps(profiles))
    result = client.post(base + "/fixture/run", request)
    require(result["status"] == "running", "Command did not lease a durable receipt")

    def receipt(identifier, status):
        match = find(client.request("GET", base + "/runs"), id=identifier)
        return match if match and match["status"] == status else None

    completed = wait_for(lambda: receipt(request["id"], "completed"), "Fixture command never completed")
    require(completed["exitCode"] == 0 and completed["output"] == "literal-fixture\n",
            "Toolkit command output or exit code changed")
    require(client.post(base + "/fixture/run", request) == completed, "Completed command was replayed")
    client.post(base + "/stop/run", request, status=409)

    stopped = client.post(base + "/stop/run", {
        **request, "id": str(uuid.uuid4()).upper(), "revision": catalog[1]["revision"]
    })
    client.post(f'{base}/runs/{stopped["id"]}/cancel', {})
    wait_for(lambda: receipt(stopped["id"], "interrupted"), "Stopping a command never ended its active state")
    leftover = client.post(base + "/child/run", {
        **request, "id": str(uuid.uuid4()).upper(), "revision": catalog[2]["revision"]
    })
    wait_for(lambda: receipt(leftover["id"], "completed"),
             "An exited command held its output pipe open through a child process")
    print("PASS confirmed exact host commands, durable output, safe retry, cancellation and process-group cleanup")


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="aides-toolkit-commands-") as folder:
        server = IsolatedServer(binary, Path(folder))
        try:
            exercise(server)
        finally:
            server.stop()


if __name__ == "__main__":
    main()
