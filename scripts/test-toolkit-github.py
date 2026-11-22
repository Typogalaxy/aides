#!/usr/bin/env python3
"""Verify GitHub Toolkit write approval and recovery with no live provider traffic."""

import argparse
import json
from pathlib import Path
import runpy
import sqlite3
import sys
import tempfile
import uuid


SMOKE = runpy.run_path(str(Path(__file__).with_name("test-server.py")))
Client, IsolatedServer, SmokeFailure, find, require = (
    SMOKE[name] for name in ("Client", "IsolatedServer", "SmokeFailure", "find", "require")
)
REPOSITORIES = "/toolkit/github/repositories"
WRITES = "/toolkit/github/writes"


def write_private(path, text):
    path.write_text(text, encoding="utf-8")
    path.chmod(0o600)


def simulate_shutdown_after_dispatch(directory, request_id):
    with sqlite3.connect(directory / "aides.sqlite3") as database:
        payload, = database.execute("SELECT payload FROM state WHERE id = 1").fetchone()
        state = json.loads(payload)
        records = state["toolkitGitHubWrites"]
        values = records.values() if isinstance(records, dict) else records[1::2]
        receipt = next(item for item in values if item["request"]["id"] == request_id)
        receipt["status"] = "submitting"
        database.execute("UPDATE state SET payload = ? WHERE id = 1", (json.dumps(state).encode(),))


def exercise(server):
    folder = server.data / "Toolkit"
    folder.mkdir(mode=0o700, parents=True)
    policy = folder / "github-repositories.json"
    config = [
        {"id": "fixture", "owner": "fixture-org", "name": "fixture-project",
         "allowedWrites": ["issue", "pullRequest"]},
        {"id": "read-only", "owner": "fixture-org", "name": "second-project", "publicRead": True},
    ]
    write_private(policy, json.dumps(config))
    token = folder / "github-fixture.token"
    write_private(token, "github-synthetic-token")
    invite = server.invite()
    anonymous = server.start()
    anonymous.request("GET", WRITES, status=401)
    owner = anonymous.post("/pair", {"code": invite, "name": "GitHub write fixture"})
    client = Client(server.port, owner["token"])

    repos = client.request("GET", REPOSITORIES)
    require(find(repos, id="fixture")["allowedWrites"] == ["issue", "pullRequest"],
            "Configured GitHub write actions were not exposed")
    require("allowedWrites" not in find(repos, id="read-only")
            and "github-synthetic-token" not in json.dumps(repos), "Read-only repository exposed writes or a credential")

    issue_id, pr_id = [str(uuid.uuid4()).upper() for _ in range(2)]
    issue = {"id": issue_id, "repositoryID": "fixture", "kind": "issue",
             "title": "Fixture issue", "body": "This data never leaves loopback."}
    anonymous.post(WRITES, issue, status=401)
    client.post(WRITES, {**issue, "repositoryID": "read-only"}, status=403)
    client.post(WRITES, {**issue, "body": "ghp_" + "Z" * 30}, status=400)
    receipt = client.post(WRITES, issue)
    require(receipt["status"] == "awaitingConfirmation" and receipt["request"] == issue
            and receipt["repositoryOwner"] == "fixture-org" and receipt["repositoryName"] == "fixture-project"
            and receipt["requestedByDeviceID"] == owner["deviceID"], "GitHub draft failed to bind the supplied content")
    require(client.post(WRITES, issue) == receipt, "Duplicate write draft changed the stored receipt")
    client.post(WRITES, {**issue, "title": "Different title"}, status=409)
    decision = f"{WRITES}/{issue_id}/decision"
    write_private(policy, json.dumps([{**config[0], "name": "replacement"}, config[1]]))
    client.post(decision, {"approved": True}, status=409)
    write_private(policy, json.dumps(config))
    token.unlink()
    client.post(decision, {"approved": True}, status=503)
    require(client.request("GET", WRITES) == [receipt],
            "Attempted approval with changed repository or missing token consumed the draft")
    require(client.post(decision, {"approved": False})["status"] == "declined", "Decline was not recorded")
    require(client.post(decision, {"approved": True})["status"] == "declined", "Declined write was reopened")

    write_private(token, "github-synthetic-token")
    pull = {**issue, "id": pr_id, "kind": "pullRequest", "head": "feature/review", "base": "main"}
    client.post(WRITES, {**pull, "head": "unapproved:feature"}, status=400)
    client.post(WRITES, pull)
    server.stop()
    simulate_shutdown_after_dispatch(server.data, pr_id)
    server.start()
    interrupted = client.post(f"{WRITES}/{pr_id}/decision", {"approved": True})
    require(interrupted["status"] == "interrupted", "An unconfirmed write was retried after restart")
    require(client.post(WRITES, pull) == interrupted, "GitHub invocation did not retain its original receipt")
    print("PASS GitHub write policy, approval durability, repository binding, and recovery without replay")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="aides-toolkit-github-") as folder:
        server = IsolatedServer(args.binary.resolve(), Path(folder).resolve())
        try:
            exercise(server)
        except (SmokeFailure, OSError, ValueError) as error:
            print(f"FAIL GitHub Toolkit smoke check ({type(error).__name__}): {error}", file=sys.stderr)
            return 1
        finally:
            server.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
