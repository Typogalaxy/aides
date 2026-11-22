#!/usr/bin/env python3
"""Verify the mail Toolkit approval lifecycle with synthetic accounts and no provider traffic."""

from pathlib import Path
import argparse
import json
import runpy
import sqlite3
import sys
import tempfile
import uuid


SMOKE = runpy.run_path(str(Path(__file__).with_name("test-server.py")))
Client = SMOKE["Client"]
IsolatedServer = SMOKE["IsolatedServer"]
SmokeFailure = SMOKE["SmokeFailure"]
require = SMOKE["require"]


def save_private(file, value):
    file.write_text(value, encoding="utf-8")
    file.chmod(0o600)


def existing_draft(client, identifier):
    return next(item for item in client.request("GET", "/toolkit/mail/drafts") if item["id"] == identifier)


def simulate_stopped_dispatch(directory, draft_id):
    with sqlite3.connect(directory / "aides.sqlite3") as database:
        payload, = database.execute("SELECT payload FROM state WHERE id = 1").fetchone()
        state = json.loads(payload)
        values = state["toolkitMailDrafts"]
        drafts = values.values() if isinstance(values, dict) else values[1::2]
        draft = next(item for item in drafts if item["id"] == draft_id)
        draft["status"] = "sending"
        database.execute("UPDATE state SET payload = ? WHERE id = 1", (json.dumps(state).encode(),))


def exercise(server):
    folder = server.data / "Toolkit"
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    account_data = [
        {"id": "work", "provider": "outlook", "label": "Work", "address": "owner@example.com", "allowSend": True},
        {"id": "home", "provider": "gmail", "label": "Home", "address": "owner@example.com"},
        {"id": "private", "provider": "fastmail", "label": "Private", "address": "owner@example.com"},
    ]
    configuration = folder / "mail-accounts.json"
    save_private(configuration, json.dumps(account_data))
    token = folder / "mail-work.token"
    save_private(token, "synthetic-mail-token")

    invite = server.invite()
    anonymous = server.start()
    accounts = "/toolkit/mail/accounts"
    drafts = "/toolkit/mail/drafts"
    anonymous.request("GET", accounts, status=401)
    anonymous.post(drafts, {}, status=401)
    owner = anonymous.post("/pair", {"code": invite, "name": "Smoke mail owner"})
    client = Client(server.port, owner["token"])

    records = client.request("GET", accounts)
    require({item["provider"] for item in records} == {"outlook", "gmail", "fastmail"},
            "Mail account discovery lost a provider")
    require("synthetic-mail-token" not in json.dumps(records), "Mail token leaked into account discovery")
    require(next(item for item in records if item["id"] == "work")["available"], "Protected token was not resolved")
    token.chmod(0o644)
    records = client.request("GET", accounts)
    require(not next(item for item in records if item["id"] == "work")["available"],
            "A group-readable token was accepted")
    token.chmod(0o600)

    first_id, second_id = [str(uuid.uuid4()).upper() for _ in range(2)]
    draft = {"id": first_id, "accountID": "work", "to": ["recipient@example.com"],
             "subject": "Smoke fixture", "body": "This draft must never reach a live provider."}
    client.post(drafts, {**draft, "accountID": "home"}, status=403)
    client.post(drafts, {**draft, "subject": "New\r\nBcc: invalid@example.com"}, status=400)
    created = client.post(drafts, draft)
    require(created["status"] == "awaitingConfirmation" and created["accountAddress"] == "owner@example.com"
            and created["requestedByDeviceID"] == owner["deviceID"], "Draft did not freeze sender and requester")
    require(client.post(drafts, draft) == created, "Retry created a duplicate draft")
    client.post(drafts, {**draft, "body": "Different body"}, status=409)
    token.unlink()
    first_decision = f"{drafts}/{first_id}/decision"
    client.post(first_decision, {"approved": True}, status=503)
    require(existing_draft(client, first_id)["status"] == "awaitingConfirmation",
            "Missing token consumed a valid draft")
    result = client.post(first_decision, {"approved": False})
    require(result["status"] == "declined", "Declining did not resolve the draft")
    require(client.post(first_decision, {"approved": True})["status"] == "declined",
            "Approval resurrected a declined draft")

    save_private(token, "synthetic-mail-token")
    client.post(drafts, {**draft, "id": second_id})
    server.stop()
    simulate_stopped_dispatch(server.data, second_id)
    server.start()
    require(existing_draft(client, second_id)["status"] == "interrupted",
            "Server restart did not mark recorded dispatch interrupted")
    require(client.post(f"{drafts}/{second_id}/decision", {"approved": True})["status"] == "interrupted",
            "An interrupted dispatch could be sent a second time")
    print("PASS mail discovery, private credential files, draft approval, and restart without replay")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="aides-toolkit-mail-") as directory:
        server = IsolatedServer(args.binary.resolve(), Path(directory).resolve())
        try:
            exercise(server)
        except (SmokeFailure, OSError, ValueError) as error:
            print(f"FAIL mail Toolkit smoke check ({type(error).__name__}): {error}", file=sys.stderr)
            return 1
        finally:
            server.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
