#!/usr/bin/env python3
"""Exercise AidesServer on loopback with temporary data and synthetic models."""

import argparse
from datetime import datetime, timedelta, timezone
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
from pathlib import Path
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import uuid


SCHEDULE_REQUEST = "Suggest a reminder for the synthetic follow-up."
SCHEDULE_REPLY = "Confirm this synthetic reminder when ready."
SCHEDULE_TITLE = "Synthetic follow-up"
SHARED_MARKER = "authorized-material-fixture"
PRIVATE_MARKER = "private-project-fixture"
UNSELECTED_MARKER = "unselected-material-fixture"


class SmokeFailure(Exception):
    pass


def require(condition, description):
    if not condition:
        raise SmokeFailure(description)


def find(items, **fields):
    return next((item for item in items if all(item.get(key) == value for key, value in fields.items())), None)


def wait_for(check, description, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.12)
    raise SmokeFailure(description)


class Client:
    def __init__(self, port, token=None):
        self.port = port
        self.token = token

    def request(self, method, route, payload=None, status=200):
        headers = {"Accept": "application/json"}
        body = None
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        if payload is not None:
            body = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"

        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            connection.request(method, "/api/v1" + route, body=body, headers=headers)
            response = connection.getresponse()
            require(response.status == status, f"{method} {route}: expected {status}, got {response.status}")
            return json.loads(response.read())
        finally:
            connection.close()

    def state(self):
        return self.request("GET", "/state")

    def post(self, route, payload, status=200):
        return self.request("POST", route, payload, status=status)


class OllamaFixture(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        if self.path != "/api/chat":
            self.send_error(404)
            return

        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        system = " ".join(
            message["content"] for message in request["messages"] if message["role"] == "system"
        )
        scope = "scoped" if PRIVATE_MARKER in system else "outside"
        answer = f'{request["model"]} / {scope}'
        text = user_text(request)
        if any("Approved task and workspace snapshots:" in item["content"] for item in request["messages"]):
            answer = json.dumps({
                "summary": "Update the isolated fixture",
                "changes": [{"path": "Example.swift", "contents": "let ready = true\n"}],
            })
        elif text == "Fixture Toolkit query scoped memory":
            evidence = [item["content"] for item in request["messages"] if item["content"].startswith("Approved local Toolkit query")]
            answer = "Local Toolkit evidence present" if any(PRIVATE_MARKER in item for item in evidence) else "No local Toolkit evidence"
        elif text == "Fixture Toolkit analyze receipt":
            evidence = "Approved local file receipt (JSON string):\n" + json.dumps("Synthetic granted folder")
            answer = "Local receipt present" if any(message["content"] == evidence for message in request["messages"]) else "No local receipt"
        elif text.startswith("Fixture Toolkit "):
            grant = re.search(r"Use resourceID ([0-9A-F-]+)", system)
            answer = json.dumps({
                "text": "Proposed fixture file action",
                "toolkit": {
                    "tool": "files.list",
                    "resourceID": grant[1] if grant and text != "Fixture Toolkit wrong resource" else str(uuid.uuid4()),
                    "path": "",
                },
            })
        elif text == SCHEDULE_REQUEST:
            first_run = datetime.now(timezone.utc) + timedelta(minutes=10)
            answer = json.dumps({
                "text": SCHEDULE_REPLY,
                "schedule": {
                    "title": SCHEDULE_TITLE,
                    "firstRun": first_run.isoformat(timespec="seconds"),
                    "timeZone": "Australia/Melbourne",
                    "repeatRule": "once",
                    "kind": "reminder",
                },
            })
        # Echo only controlled markers, never the prompt or API credentials.
        response = json.dumps({
            "message": {"role": "assistant", "content": answer},
            "done": True,
            "prompt_eval_count": 7,
            "eval_count": 3,
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)


def user_text(request):
    return next(
        (message["content"] for message in reversed(request["messages"]) if message["role"] == "user"),
        "",
    )


class IsolatedServer:
    def __init__(self, binary, temporary):
        self.binary = binary
        self.data = temporary / "data"
        self.environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "AIDES_DATA_DIR": str(self.data),
            "AIDES_HOST": "127.0.0.1",
        }
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.port = listener.getsockname()[1]
        fixture = temporary / "codex-fixture"
        fixture.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "prompt=$(/bin/cat)\n"
            "case \"$prompt\" in\n"
            f"  *{PRIVATE_MARKER}*|*{UNSELECTED_MARKER}*) printf '%s' 'Unexpected memory disclosure' ;;\n"
            f"  *{SHARED_MARKER}*) printf '%s' 'Approved fixture review with selected memory' ;;\n"
            "  *) printf '%s' 'Approved fixture review' ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        fixture.chmod(0o700)
        self.environment["AIDES_CODEX_PATH"] = str(fixture)
        self.environment["AIDES_PORT"] = str(self.port)
        self.process = None

    def invite(self):
        result = subprocess.run(
            [str(self.binary), "invite"], env=self.environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10,
        )
        require(result.returncode == 0, f"Server invite command exited with status {result.returncode}")
        code = result.stdout.strip()
        require(re.fullmatch(r"[a-f0-9]{64}", code), "Server CLI did not issue an invitation")
        return code

    def start(self):
        self.process = subprocess.Popen(
            [str(self.binary), "serve"], env=self.environment,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        client = Client(self.port)

        def ready():
            require(self.process.poll() is None, "Server exited before becoming ready")
            try:
                return client.request("GET", "/health").get("status") == "ok"
            except (ConnectionError, TimeoutError):
                return False

        wait_for(ready, "Server did not become ready")
        return client

    def stop(self):
        if self.process is None:
            return
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.process = None


def wait_for_task(client, identifier, status):
    def check():
        task = find(client.state()["tasks"], id=identifier)
        if task is None:
            return None
        if task["status"] == status:
            return task
        if task["status"] in {"failed", "cancelled", "completed"}:
            raise SmokeFailure(f'Task ended in {task["status"]} while waiting for {status}')
        return None

    return wait_for(check, f"Task never reached {status}")


def wait_for_reply(client, thread, expected):
    def check():
        conversation = find(client.state()["threads"], id=thread)
        return find(conversation["messages"], role="assistant", text=expected)

    return wait_for(check, "Conversation reply was missing or had the wrong local context")


def add_model(client, name, kind, model, endpoint=""):
    state = client.post("/models", {"name": name, "kind": kind, "model": model, "endpoint": endpoint})
    return find(state["models"], name=name)["id"]


def verify_cloud_memory(client, project_thread, scope, model, private_memory):
    selected = {"key": "Selected fixture fact", "value": SHARED_MARKER,
                "scope": scope, "sensitivity": "cloudAllowed"}
    saved = find(client.post("/memory", selected), key=selected["key"])
    client.post("/memory", {"key": "Unselected fixture fact", "value": UNSELECTED_MARKER,
                            "scope": "global", "sensitivity": "cloudAllowed"})
    request = {"title": "Cloud fixture with selected memory", "modelID": model, "threadID": project_thread}
    client.post("/tasks", {**request, "sharedMemoryIDs": [private_memory]}, status=403)
    client.post("/tasks", {**request, "threadID": None, "sharedMemoryIDs": [saved["id"]]}, status=403)
    state = client.post("/tasks", {**request, "sharedMemoryIDs": [saved["id"]]})
    task = find(state["tasks"], title=request["title"])
    require(task["status"] == "waitingApproval", "Sharing memory bypassed cloud approval")
    client.post(f'/tasks/{task["id"]}/approve', {"approved": True})
    result = wait_for_task(client, task["id"], "completed")
    require(result["result"] == "Approved fixture review with selected memory",
            "Cloud fixture did not receive exactly the selected memory")

    title = "Cloud fixture with revoked memory"
    state = client.post("/tasks", {**request, "title": title, "sharedMemoryIDs": [saved["id"]]})
    task = find(state["tasks"], title=title)
    client.post("/memory", {**selected, "sensitivity": "localOnly"})
    client.post(f'/tasks/{task["id"]}/approve', {"approved": True})
    blocked = wait_for_task(client, task["id"], "waiting")
    require("shared memory" in blocked.get("error", ""), "Revocation did not prevent dispatch")


def exercise_toolkit(anonymous, client, target, owner, grant):
    catalog_path = "/toolkit/catalog"
    invocations = "/toolkit/invocations"
    anonymous.request("GET", catalog_path, status=401)
    catalog = client.request("GET", catalog_path)
    approvals = {tool["id"]: tool["approval"] for tool in catalog["tools"]}
    require(approvals.get("files.list") == "grantedResource"
            and approvals.get("files.read") == "grantedResource"
            and approvals.get("files.move") == "targetDevice",
            "Toolkit file actions did not advertise their approval requirements")
    resource = find(catalog["resources"], id=grant["id"])
    require(resource is not None and resource["deviceID"] == grant["deviceID"]
            and set(resource["tools"]) == {"files.list", "files.read"},
            "Toolkit catalog exposed move access for a read-only folder")

    read = {
        "id": str(uuid.uuid4()).upper(), "tool": "files.read",
        "resourceID": resource["id"], "path": "Notes.txt",
    }
    lookup = f'{invocations}/{read["id"]}'
    anonymous.post(invocations, read, status=401)
    anonymous.request("GET", lookup, status=401)
    client.request("GET", lookup, status=404)
    client.post(invocations, {**read, "path": "../Outside.txt"}, status=400)
    client.post(invocations, {**read, "tool": "files.move", "destination": "Renamed.txt"}, status=403)

    queued = client.post(invocations, read)
    require(queued["id"] == read["id"] and queued["tool"] == read["tool"] and queued["status"] == "queued"
            and queued["resourceID"] == grant["id"] and queued["deviceID"] == grant["deviceID"]
            and queued["requestedByDeviceID"] == owner["deviceID"],
            "Toolkit request lost its operation, resource, or device attribution")
    require(client.post(invocations, read) == queued, "Toolkit retry created a second invocation")
    client.post(invocations, {**read, "path": "Other.txt"}, status=409)
    target.post(invocations, read, status=409)
    require(client.post("/device-files/jobs/next", {}).get("job") is None,
            "Requester claimed a Toolkit operation assigned to another device")
    claimed = target.post("/device-files/jobs/next", {})["job"]
    require(claimed["id"] == read["id"] and claimed["operation"] == "read",
            "The file relay did not claim the Toolkit invocation")
    require(client.request("GET", lookup)["status"] == "running", "Toolkit status did not reflect the relay claim")
    finish = f'/device-files/jobs/{read["id"]}/finish'
    client.post(finish, {"result": "Untrusted receipt"}, status=404)
    target.post(finish, {"result": "Synthetic Toolkit result"})
    completed = client.request("GET", lookup)
    require(completed["status"] == "completed" and completed["result"] == "Synthetic Toolkit result",
            "Toolkit status did not return the relay receipt")
    require(client.post(invocations, read) == completed, "A completed Toolkit invocation was dispatched again")
    require(target.post("/device-files/jobs/next", {}).get("job") is None,
            "A Toolkit retry left a duplicate job on the file relay")
    print("PASS Toolkit discovery, grant checks, shared relay, and idempotent invocation")
    return completed


def exercise_toolkit_writes(client):
    read_only = client.post("/device-files/grants", {"name": "Files read-only"})
    write = client.post("/device-files/grants", {"name": "Files text", "allowWrites": True})
    query = "?writes=true"
    catalog = client.request("GET", "/toolkit/catalog" + query)
    tools = find(catalog["resources"], id=write["id"])["tools"]
    require("files.create" in tools and "files.replace" in tools and "files.move" not in tools,
            "Write and move permissions were not independent")
    create = {"id": str(uuid.uuid4()).upper(), "tool": "files.create", "resourceID": write["id"],
              "path": "Draft.txt", "text": "New text"}
    url = "/toolkit/invocations"
    client.post(url, {**create, "resourceID": read_only["id"]}, status=403)
    client.post(url, {**create, "path": "mail-test.token"}, status=400)
    client.post(url, {**create, "text": "a" * 4097}, status=400)
    submitted = client.post(url, create)
    client.post(url, {**create, "text": "Different text"}, status=409)
    require(find(client.request("GET", "/device-files")["jobs"], id=submitted["id"]) is None,
            "A legacy client saw an unsupported write")
    require(client.post("/device-files/jobs/next", {}).get("job") is None, "A legacy client claimed a write")
    claim = client.post("/device-files/jobs/next" + query, {})["job"]
    require(claim["id"] == submitted["id"] and claim["text"] == create["text"],
            "Approved-write relay did not receive exactly the proposed text")
    client.post(f'/device-files/jobs/{claim["id"]}/finish', {"error": "Target Mac declined the file change."})
    require(client.post(url, create)["status"] == "failed", "Declined write was dispatched again")
    replace = {**create, "id": str(uuid.uuid4()).upper(), "tool": "files.replace", "expectedText": "Old text"}
    client.post(url, {key: value for key, value in replace.items() if key != "expectedText"}, status=400)
    queued = client.post(url, replace)
    client.request("DELETE", f'/device-files/grants/{write["id"]}' + query)
    require(client.request("GET", f'{url}/{queued["id"]}')["status"] == "cancelled",
            "Revoked grant left a write queued")
    print("PASS independent file write grants, target relay, and legacy compatibility")


def exercise_toolkit_models(anonymous, client, secretary, cloud):
    grant = client.post("/device-files/grants", {"name": "One request only", "allowMoves": False})
    payload = {"text": "Fixture Toolkit list files", "toolkitResourceID": grant["id"]}
    thread = f"/threads/{secretary}/messages"
    client.post(thread, {**payload, "toolkitResourceID": str(uuid.uuid4())}, status=404)
    client.post(thread, payload)
    reply = wait_for_reply(client, secretary, "Proposed fixture file action")
    require(reply["toolkitSuggestion"]["resourceID"] == grant["id"], "Secretary lost the task-specific folder")
    require(client.post("/device-files/jobs/next", {}).get("job") is None, "Secretary dispatched without confirmation")
    accept = f'/toolkit/suggestions/{reply["id"]}/accept'
    anonymous.post(accept, {}, status=401)
    accepted = client.post(accept, {})
    require(accepted["id"] == reply["id"] and accepted["status"] == "queued",
            "Confirmation did not freeze the proposed command")
    require(client.post(accept, {}) == accepted, "Repeated chat confirmation added a duplicate tool task")
    client.post("/device-files/jobs/next", {})
    client.post(f'/device-files/jobs/{accepted["id"]}/finish', {"result": "Synthetic granted folder"})

    client.post("/tasks", {"title": "External Toolkit worker", "modelID": cloud,
                           "toolkitResourceID": grant["id"]}, status=403)
    selection = {"title": "Receipt analysis", "instruction": "Fixture Toolkit analyze receipt",
                 "toolkitInvocationID": accepted["id"]}
    client.post("/tasks", {**selection, "modelID": cloud}, status=403)
    state = client.post("/tasks", selection)
    analyzed = wait_for_task(client, find(state["tasks"], title=selection["title"])["id"], "completed")
    require(analyzed["result"] == "Local receipt present", "Selected file receipt did not reach the local Worker")
    state = client.post("/tasks", {"title": "Scoped Toolkit worker", "instruction": payload["text"],
                                   "toolkitResourceID": grant["id"]})
    worker = wait_for_task(client, find(state["tasks"], title="Scoped Toolkit worker")["id"], "completed")
    require(worker["toolkitSuggestion"]["resourceID"] == grant["id"], "Local Worker did not propose the tool")
    client.request("DELETE", f'/device-files/grants/{grant["id"]}')
    client.post(f'/toolkit/suggestions/{worker["id"]}/accept', {}, status=409)
    client.post("/tasks", selection, status=403)
    require(client.post("/device-files/jobs/next", {}).get("job") is None, "Revoked proposal still dispatched")
    anonymous.request("GET", "/toolkit/audit", status=401)
    audit = client.request("GET", "/toolkit/audit")
    require(any(entry["status"] == 409 and "suggestions" in entry["action"] for entry in audit),
            "Toolkit authorization rejection was not recorded")
    require("Synthetic granted folder" not in json.dumps(audit) and accepted["id"] not in json.dumps(audit),
            "Toolkit audit logged request identifiers or receipt contents")
    print("PASS Toolkit secretary and Worker scoping, confirmation, revocation, and audit")


def exercise(server, mock_ollama):
    invite = server.invite()
    anonymous = server.start()
    anonymous.request("GET", "/state", status=401)
    owner = anonymous.post("/pair", {"code": invite, "name": "Smoke owner"})
    anonymous.post("/pair", {"code": invite, "name": "Reused invitation"}, status=403)

    client = Client(server.port, owner["token"])
    guest_invite = client.post("/pair/invites", {})["code"]
    guest = anonymous.post("/pair", {"code": guest_invite, "name": "Smoke guest"})
    guest_client = Client(server.port, guest["token"])
    guest_client.request("GET", "/state")
    grant = guest_client.post("/device-files/grants", {"name": "Read-only smoke folder", "allowMoves": False})
    read = {"grantID": grant["id"], "operation": "read", "path": "Readme.txt"}
    client.post("/device-files/jobs", {**read, "path": "../Outside.txt"}, status=400)
    client.post("/device-files/jobs", {**read, "operation": "move", "destination": "Renamed.txt"}, status=403)
    job = client.post("/device-files/jobs", read)
    require(client.post("/device-files/jobs/next", {}).get("job") is None, "Wrong device claimed a file operation")
    claimed = guest_client.post("/device-files/jobs/next", {})["job"]
    require(claimed["id"] == job["id"] and claimed["status"] == "running", "Target device could not claim its job")
    finish = f'/device-files/jobs/{job["id"]}/finish'
    client.post(finish, {"result": "Untrusted receipt"}, status=404)
    receipt = guest_client.post(finish, {"result": "Synthetic text fixture"})
    require(receipt["status"] == "completed", "Target device did not complete its file job")
    toolkit_receipt = exercise_toolkit(anonymous, client, guest_client, owner, grant)
    queued = client.post("/device-files/jobs", read)
    client.request("DELETE", "/devices/" + guest["deviceID"])
    revoked_files = client.request("GET", "/device-files")
    require(find(revoked_files["grants"], id=grant["id"]) is None, "Device revocation left a folder grant active")
    require(find(revoked_files["jobs"], id=queued["id"])["status"] == "cancelled", "Device revocation left a queued job active")
    guest_client.request("GET", "/state", status=401)
    print("PASS device authentication, isolated file claims, and grant revocation")

    state = client.post("/projects", {"name": "Fixture project"})
    project = find(state["projects"], name="Fixture project")
    path = Path(project["directory"])
    require(path.is_dir() and path.resolve().is_relative_to(server.data.resolve()), "Project directory was not isolated")
    project_thread = find(state["threads"], role="project", projectID=project["id"])["id"]
    secretary = find(state["threads"], role="secretary")["id"]
    state = client.post("/threads", {"title": "Fixture follow-up", "role": "task", "projectID": project["id"]})
    require(find(state["threads"], title="Fixture follow-up")["projectID"] == project["id"], "Task thread lost its project")
    events = client.request("GET", f'/events?after={state["revision"] - 1}')
    require(events["revision"] >= state["revision"], "Event state did not include the latest revision")

    mock = add_model(client, "Mock A", "mock", "mock-a")
    require(client.state()["settings"]["defaultModelID"] == mock, "First local model was not selected as default")
    client.post(f"/threads/{secretary}/messages", {"text": "Start an isolated smoke test."})
    wait_for_reply(client, secretary, "Test model received: Start an isolated smoke test.")
    print("PASS project threads, revision sync, and offline mock reply")

    scope = "project:" + project["id"].lower()
    memory = {"key": "Fixture marker", "value": "outdated-fixture", "scope": scope, "sensitivity": "localOnly"}
    before = client.post("/memory", memory)[0]
    memory["value"] = PRIVATE_MARKER
    after = client.post("/memory", memory)
    require(len(after) == 1 and after[0]["id"] == before["id"], "Memory update was not stable")
    require(client.request("GET", "/memory")[0]["value"] == memory["value"], "Memory update was not saved")
    client.post("/memory", {**memory, "scope": "unknown:scope"}, status=400)
    endpoint = f"http://127.0.0.1:{mock_ollama.server_port}"
    local_a = add_model(client, "Local A", "ollama", "fixture-a", endpoint)
    local_b = add_model(client, "Local B", "ollama", "fixture-b", endpoint)
    state = client.post("/settings", {"defaultModelID": local_a, "preference": "Use short replies."})
    require(state["settings"]["preferenceRevision"] > 0, "Preference revision was not incremented")
    client.post(f"/threads/{project_thread}/messages", {"text": "What is the fixture marker?"})
    wait_for_reply(client, project_thread, "fixture-a:local / scoped")
    client.post(f"/threads/{secretary}/messages", {"text": "What is the fixture marker?"})
    wait_for_reply(client, secretary, "fixture-a:local / outside")
    print("PASS scoped memory reaches only the correct local model context")

    due = (datetime.now(timezone.utc) + timedelta(seconds=3)).isoformat(timespec="milliseconds")
    state = client.post("/tasks", {"title": "Pinned analysis", "kind": "analysis", "scheduledAt": due})
    pinned = find(state["tasks"], title="Pinned analysis")
    require(pinned["status"] == "scheduled" and pinned["modelID"] == local_a, "Future task was not created and pinned")
    state = client.post("/schedules", {
        "title": "Fixture reminder", "threadID": secretary, "kind": "reminder",
        "repeatRule": "once", "timeZone": "Australia/Melbourne", "firstRun": due,
    })
    schedule = find(state["schedules"], title="Fixture reminder")
    client.post("/settings", {"defaultModelID": local_b})
    task = wait_for_task(client, pinned["id"], "completed")
    require(task["modelID"] == local_a and task["result"] == "fixture-a:local / outside", "Changing the default moved the existing task")
    wait_for_reply(client, secretary, "Fixture reminder")
    print("PASS delayed worker pinning and scheduled reminder delivery")

    client.post(f"/threads/{secretary}/messages", {"text": SCHEDULE_REQUEST})
    reply = wait_for_reply(client, secretary, SCHEDULE_REPLY)
    suggestion = reply["scheduleSuggestion"]
    require(suggestion["title"] == SCHEDULE_TITLE, "Secretary did not propose the expected reminder")
    require(not find(client.state()["schedules"], title=SCHEDULE_TITLE), "Suggestion scheduled a reminder without approval")
    accept_schedule = f'/schedules/suggestions/{reply["id"]}/accept'
    anonymous.post(accept_schedule, {}, status=401)
    state = client.post(accept_schedule, {})
    accepted = find(state["schedules"], title=SCHEDULE_TITLE)
    require(accepted is not None, "Confirmation did not create a reminder")
    for key in ("title", "kind", "repeatRule", "timeZone", "firstRun"):
        require(accepted[key] == suggestion[key], f"Confirmation changed the proposed {key}")
    require(accepted["threadID"] == secretary, "Reminder lost its originating conversation")
    state = client.post(accept_schedule, {})
    require([item["id"] for item in state["schedules"] if item["title"] == SCHEDULE_TITLE] == [accepted["id"]],
            "Repeating confirmation created another reminder")
    print("PASS explicit and idempotent secretary reminder confirmation")

    cloud = add_model(client, "Approved fixture", "codex", "fixture-model")
    exercise_toolkit_models(anonymous, client, secretary, cloud)
    exercise_toolkit_writes(client)
    selection = {"action": "memory.search", "query": "Fixture marker", "limit": 3}
    scoped = {"title": "Scoped local query", "instruction": "Fixture Toolkit query scoped memory",
              "threadID": project_thread, "toolkitLocalSelection": selection}
    client.post("/tasks", {**scoped, "modelID": cloud}, status=403)
    client.post("/tasks", {**scoped, "toolkitLocalSelection": {"action": "projects.files.read",
                      "path": "../Outside.txt"}}, status=400)
    state = client.post("/tasks", scoped)
    task = wait_for_task(client, find(state["tasks"], title=scoped["title"])["id"], "completed")
    require(task["result"] == "Local Toolkit evidence present", "Scoped memory did not reach the local Worker")
    outside = {"title": "Outside local query", "instruction": scoped["instruction"], "toolkitLocalSelection": selection}
    state = client.post("/tasks", outside)
    task = wait_for_task(client, find(state["tasks"], title=outside["title"])["id"], "completed")
    require(task["result"] == "No local Toolkit evidence", "A local Worker received an out-of-scope query result")
    print("PASS Local Toolkit query results respect Worker scope and local-only routing")
    state = client.post("/tasks", {"title": "Cloud fixture request", "modelID": cloud})
    cloud_task = find(state["tasks"], title="Cloud fixture request")
    require(cloud_task["status"] == "waitingApproval" and not cloud_task["approvedCloud"], "Cloud execution bypassed approval")
    client.post("/tasks/" + cloud_task["id"] + "/approve", {"approved": True})
    result = wait_for_task(client, cloud_task["id"], "completed")
    require(result["result"] == "Approved fixture review", "Approved command fixture did not return its report")
    verify_cloud_memory(client, project_thread, scope, cloud, before["id"])
    print("PASS cloud memory selection is scoped, explicit, and revocable before dispatch")

    state = client.post("/reviews", {
        "title": "Review fixture", "instruction": "Choose a storage format.", "modelIDs": [local_a, local_b],
        "threadID": project_thread,
    })
    review = find(state["tasks"], title="Review fixture", kind="review")

    def report_ready():
        result = find(client.state()["tasks"], id=review["id"])
        return result["status"] == "waiting" and "Independent interpretations" in (result.get("result") or "")

    wait_for(report_ready, "Independent review reports were not ready for clarification")
    client.post("/reviews/" + review["id"] + "/clarify", {"clarification": "Prefer plain text."})
    done = wait_for_task(client, review["id"], "completed")
    require("Follow-up interpretations" in done["result"], "Review did not include the follow-up round")
    print("PASS explicit external approval and structured review")

    file = path / "Example.swift"
    original = "let ready = false\n"
    file.write_text(original, encoding="utf-8")
    request = {
        "title": "Isolated code proposal", "instruction": "Set ready to true.",
        "modelID": local_a, "projectID": project["id"], "paths": ["Example.swift"],
    }
    client.post("/code-proposals", {**request, "paths": ["../Outside.swift"]}, status=400)
    state = client.post("/code-proposals", request)
    proposal = find(state["tasks"], title=request["title"], kind="codeProposal")
    wait_for_task(client, proposal["id"], "completed")
    proposal_path = f'/code-proposals/{proposal["id"]}'
    details = client.request("GET", proposal_path)
    require(details["changes"][0]["originalContents"] == original, "Proposal lost its review baseline")
    require(file.read_text(encoding="utf-8") == original, "Generating a proposal edited the file")
    file.write_text("local concurrent edit\n", encoding="utf-8")
    apply = {"path": "Example.swift"}
    client.post(proposal_path + "/apply", apply, status=409)
    require(file.read_text(encoding="utf-8") == "local concurrent edit\n", "Apply overwrote a conflicting edit")
    file.write_text(original, encoding="utf-8")
    client.post(proposal_path + "/apply", apply)
    client.post(proposal_path + "/apply", apply)
    require(file.read_text(encoding="utf-8") == "let ready = true\n", "Explicit apply did not update the file")
    require(client.request("GET", proposal_path)["appliedPaths"] == ["Example.swift"], "Apply was not idempotent")
    print("PASS code proposal isolation, stale-file refusal, and explicit application")

    folder = client.post("/device-files/grants", {"name": "Move-enabled smoke folder", "allowMoves": True})
    move = {
        "id": str(uuid.uuid4()).upper(), "tool": "files.move", "resourceID": folder["id"],
        "path": "Before.txt", "destination": "After.txt",
    }
    client.post("/toolkit/invocations", move)
    claimed = client.post("/device-files/jobs/next", {})["job"]
    require(claimed["id"] == move["id"] and claimed["operation"] == "move" and claimed["status"] == "running",
            "Move invocation did not reach the device relay for confirmation")

    server.stop()
    legacy_ids = seed_legacy_mail(server.data, cloud_task)
    server.start()
    restored = client.state()
    require(client.request("GET", f'/toolkit/invocations/{toolkit_receipt["id"]}') == toolkit_receipt,
            "Completed Toolkit receipt changed after restart")
    interrupted = client.request("GET", f'/toolkit/invocations/{move["id"]}')
    require(interrupted["status"] == "interrupted", "A claimed Toolkit move was not interrupted on restart")
    require(client.post("/toolkit/invocations", move) == interrupted, "Restart made a Toolkit move retry unsafe")
    require(client.post("/device-files/jobs/next", {}).get("job") is None, "Restart replayed a claimed Toolkit move")
    client.post(f'/device-files/jobs/{move["id"]}/finish', {"result": "Late receipt"}, status=409)
    print("PASS durable Toolkit receipts and restart without replaying a claimed move")
    queued_mail, completed_mail = (find(restored["tasks"], id=identifier) for identifier in legacy_ids)
    require(queued_mail["status"] == "cancelled", "Old mail work was left eligible to run")
    require(completed_mail["status"] == "completed", "Completed mail history was changed")
    client.post(f'/tasks/{legacy_ids[0]}/resume', {}, status=409)
    client.post(f'/mail/suggestions/{legacy_ids[0]}/send', {}, status=404)
    print("PASS retired local mail tasks cannot be submitted or resumed")
    require(find(restored["projects"], id=project["id"]), "Project disappeared after restart")
    require(restored["settings"]["defaultModelID"] == local_b, "Default model did not persist")
    require(find(restored["tasks"], id=review["id"])["status"] == "completed", "Review did not persist")
    require(client.request("GET", proposal_path)["appliedPaths"] == ["Example.swift"], "Approval did not persist")
    require(find(client.request("GET", "/memory"), id=before["id"])["value"] == memory["value"],
            "Scoped memory did not persist")
    completed = [task for task in restored["tasks"] if task.get("scheduleID") == schedule["id"]]
    require(len(completed) == 1 and completed[0]["status"] == "completed", "Reminder was lost or repeated")
    require(find(restored["schedules"], id=schedule["id"]).get("nextRun") is None, "One-time schedule was left active")
    state = client.post(accept_schedule, {})
    require([item["id"] for item in state["schedules"] if item["title"] == SCHEDULE_TITLE] == [accepted["id"]],
            "Reminder confirmation did not persist across restart")
    guest_client.request("GET", "/state", status=401)
    print("PASS durable state, one-time schedules, and persisted device revocation")

    # Rotate the original move receipt out with newer terminal file requests.
    for _ in range(32):
        job = client.post("/device-files/jobs", {"grantID": folder["id"], "operation": "list", "path": ""})
        claim = client.post("/device-files/jobs/next", {})["job"]
        require(claim["id"] == job["id"], "History rotation unexpectedly replayed an earlier invocation")
        client.post(f'/device-files/jobs/{job["id"]}/finish', {"result": "Synthetic directory listing"})
    client.request("GET", f'/toolkit/invocations/{move["id"]}', status=410)
    client.post("/toolkit/invocations", move, status=410)
    require(client.post("/device-files/jobs/next", {}).get("job") is None,
            "A Toolkit invocation was replayed after its receipt expired")
    print("PASS expired Toolkit receipts cannot cause a second dispatch")


def seed_legacy_mail(directory, template):
    identifiers = [str(uuid.uuid4()).upper() for _ in range(2)]
    with sqlite3.connect(directory / "aides.sqlite3") as connection:
        payload, = connection.execute("SELECT payload FROM state WHERE id = 1").fetchone()
        state = json.loads(payload)
        for identifier, status in zip(identifiers, ("queued", "completed")):
            state["app"]["tasks"].append(dict(template, id=identifier, kind="mail", status=status))
        connection.execute("UPDATE state SET payload = ? WHERE id = 1", (json.dumps(state).encode(),))
    return identifiers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, help="Path to a built AidesServer")
    args = parser.parse_args()
    binary = args.binary.expanduser().resolve()
    if not binary.is_file():
        parser.error("The AidesServer binary does not exist")

    try:
        with tempfile.TemporaryDirectory(prefix="aides-smoke-") as directory:
            server = IsolatedServer(binary, Path(directory).resolve())
            with ThreadingHTTPServer(("127.0.0.1", 0), OllamaFixture) as mock_ollama:
                fixture_thread = threading.Thread(target=mock_ollama.serve_forever, daemon=True)
                fixture_thread.start()
                try:
                    exercise(server, mock_ollama)
                finally:
                    server.stop()
                    mock_ollama.shutdown()
                    fixture_thread.join()
    except SmokeFailure as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        # Unexpected exceptions can contain raw request data or command output.
        print(f"FAIL smoke test could not complete ({type(error).__name__})", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
