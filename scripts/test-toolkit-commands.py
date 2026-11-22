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
    server.environment["AIDES_TOOLKIT_COMMANDS"] = json.dumps([
        account, {**account, "id": "stop", "executable": "/bin/sleep", "arguments": ["20"], "timeoutSeconds": 25}
    ])
    server.start()

    base = "/toolkit/commands"
    anonymous.request("GET", base, status=401)
    catalog = client.request("GET", base)
    require(len(catalog) == 2 and "arguments" not in catalog[0] and "executable" not in catalog[0],
            "Command catalog exposed operator-only configuration")
    request = {"id": str(uuid.uuid4()).upper(), "approved": False}
    client.post(base + "/fixture/run", request, status=403)
    require(not client.request("GET", base + "/runs"), "Unconfirmed command created a receipt")
    request["approved"] = True
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

    stopped = client.post(base + "/stop/run", {**request, "id": str(uuid.uuid4()).upper()})
    client.post(f'{base}/runs/{stopped["id"]}/cancel', {})
    wait_for(lambda: receipt(stopped["id"], "interrupted"), "Stopping a command never ended its active state")
    print("PASS confirmed host commands, durable output, safe retry, and cancellation")


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
