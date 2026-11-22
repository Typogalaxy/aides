#!/usr/bin/env python3
"""Exercise paired Computer Use and one-shot window context without a desktop or provider account."""

import base64
import json
import runpy
import sqlite3
import sys
import tempfile
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

fixtures = runpy.run_path(str(Path(__file__).with_name("test-server.py")))
Client = fixtures["Client"]
IsolatedServer = fixtures["IsolatedServer"]
add_model = fixtures["add_model"]
find = fixtures["find"]
require = fixtures["require"]
wait_for = fixtures["wait_for"]
BASE = "/toolkit/computer"
TEXTEDIT = "com.apple.TextEdit"
CALCULATOR = "com.apple.calculator"
RAW_OBSERVATION = "visible-reference-from-AX"
RAW_ATTACHMENT = "one-shot-window-content-only"
JPEG = base64.b64encode(b"\xff\xd8\xff\xd9").decode()


class ModelFixture(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        require(self.path == "/api/chat", "Computer Use called the wrong local endpoint")
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        user_messages = [item for item in request["messages"] if item["role"] == "user"]
        if request.get("format") == "json":
            evidence = json.loads(user_messages[-1]["content"])
            recent = evidence["recent"]
            if "Background" in evidence["instruction"]:
                response = {"kind": "key", "appID": TEXTEDIT, "key": "Return"}
            elif len(recent) == 1:
                require(evidence["appID"] == TEXTEDIT, "The pinned first app did not reach the model")
                require(bool(user_messages[-1].get("images")) == evidence["hasImage"], "Image scope was lost")
                response = {
                    "kind": "typeText", "appID": TEXTEDIT, "elementID": "text", "text": "Replacement in the fixture",
                }
            elif len(recent) == 2:
                require("Replacement in the fixture" in user_messages[-1]["content"], "Model could not verify the updated text")
                response = {"kind": "activate", "appID": CALCULATOR}
            else:
                require(evidence["appID"] == CALCULATOR, "Granted multi-app routing failed")
                require("Replacement in the fixture" in json.dumps(evidence["priorWindows"]),
                        "Previous authorized selected text did not survive an app switch")
                response = {"kind": "finish", "text": "Verified both fixture windows."}
            answer = json.dumps(response)
        else:
            require(any(RAW_ATTACHMENT in item["content"] and item.get("images") for item in user_messages),
                    "The selected window was not included in the local chat reply")
            answer = "Analyzed the one-time window."
        payload = json.dumps({"message": {"role": "assistant", "content": answer}, "done": True}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def token():
    return str(uuid.uuid4()).upper()


def allowance(client, run, **options):
    return client.post(f'{BASE}/runs/{run["id"]}/permission', {"approved": True, **options})


def latest(client, run, status):
    def status_match():
        entry = find(client.request("GET", BASE + "/runs"), id=run["id"])
        return entry if entry is not None and entry["status"] == status else None

    return wait_for(status_match, f"Computer Use did not reach {status}")


def next_step(client, run, action):
    command = client.post(BASE + "/next", {}).get("command")
    require(command and command["runID"] == run["id"] and command["action"]["kind"] == action,
            f"Target Mac did not claim {action}")
    check = f'{BASE}/runs/{run["id"]}/commands/{command["id"]}'
    require(client.request("GET", check)["status"] == "running", "The claimed step did not validate")
    require(client.post(BASE + "/next", {}).get("command") is None, "A step could be claimed twice")
    return command


def observe(app=TEXTEDIT, value=RAW_OBSERVATION, include_image=False, background=False):
    result = {
        "appID": app, "windowTitle": "Fixture window",
        "elements": [{"id": "text", "role": "AXTextArea", "label": "Document", "value": value}],
        "isBackground": background,
    }
    if include_image:
        result["screenshot"] = JPEG
    return result


def receipt(client, run, step, observation, status=200):
    return client.post(f'{BASE}/runs/{run["id"]}/receipt', {
        "commandID": step["id"], "observation": observation,
    }, status=status)


def exercise(server, model):
    invite = server.invite()
    anonymous = server.start()
    owner = anonymous.post("/pair", {"code": invite, "name": "Computer task requester"})
    client = Client(server.port, owner["token"])

    def pair(name):
        code = client.post("/pair/invites", {})["code"]
        profile = anonymous.post("/pair", {"code": code, "name": name})
        return Client(server.port, profile["token"]), profile["deviceID"]

    target, target_id = pair("Target Mac")
    spectator, _ = pair("Unrelated paired Mac")
    base = {"id": token(), "deviceID": target_id, "appIDs": [TEXTEDIT, CALCULATOR],
            "instruction": "Replace selected text and inspect the second app.", "includeImages": True}
    anonymous.request("GET", BASE + "/runs", status=401)
    client.post(BASE + "/runs", base, status=400)
    add_model(client, "Local Computer Fixture", "ollama", "fixture", f"http://127.0.0.1:{model.server_port}")
    thread = find(client.state()["threads"], role="secretary")["id"]
    base["threadID"] = thread
    client.post(BASE + "/runs", {**base, "appIDs": ["com.apple.Passwords"]}, status=400)
    run = client.post(BASE + "/runs", base)
    require(run["status"] == "awaitingPermission", "Computer Use did not require local permission")
    require(client.post(BASE + "/runs", base) == run, "Retried creation was replayed")
    require(not spectator.request("GET", BASE + "/runs"), "An unrelated device saw the task")
    spectator.post(f'{BASE}/runs/{run["id"]}/stop', {}, status=404)
    client.post(f'{BASE}/runs/{run["id"]}/permission', {"approved": True}, status=404)
    require(target.post(BASE + "/next", {}).get("command") is None, "Work started without target permission")
    allowance(target, run)
    require(client.post(BASE + "/next", {}).get("command") is None, "The requester claimed someone else's desktop")
    step = next_step(target, run, "observe")
    receipt(client, run, step, observe(), status=404)
    receipt(target, run, step, observe(app=CALCULATOR), status=400)
    screenshot = observe(include_image=True)
    receipt(target, run, step, screenshot)
    pending = latest(target, run, "awaitingApproval")
    require(pending["pendingReview"]["label"] == "Document", "Approval did not name the observed control")
    requester_view = latest(client, run, "awaitingApproval")
    require("pendingAction" not in requester_view and "pendingReview" not in requester_view,
            "The target's proposed text or observation leaked to another Mac")
    decision = f'{BASE}/runs/{run["id"]}/decision'
    target.post(decision, {"approved": True, "actionID": token()}, status=409)
    target.post(decision, {"approved": True, "actionID": pending["pendingCommandID"]})
    step = next_step(target, run, "typeText")
    receipt(target, run, step, observe(value="Replacement in the fixture", include_image=True))
    latest(target, run, "queued")
    step = next_step(target, run, "activate")
    receipt(target, run, step, observe(app=CALCULATOR, value="0"))
    completed = latest(client, run, "completed")
    require(completed["result"] == "Verified both fixture windows." and len(completed["steps"]) == 3,
            "The verified task result was not recorded")
    messages = find(client.state()["threads"], id=thread)["messages"]
    require(find(messages, text="Computer Use: Verified both fixture windows."), "The originating chat lost the completed result")
    print("PASS Computer Use target authorization, visual planning, exact approval and verified multi-app workflow")

    queued = client.post(BASE + "/runs", {**base, "id": token(), "includeImages": False,
                                         "instruction": "Background only, please inspect the window."})
    allowance(target, queued, allowBackground=True)
    step = next_step(target, queued, "observe")
    require(step["allowBackground"], "Background intent did not reach the target")
    receipt(target, queued, step, observe(background=True))
    latest(target, queued, "paused")
    require(target.post(BASE + "/next", {}).get("command") is None, "Background mode dispatched a keyboard command")
    target.post(f'{BASE}/runs/{queued["id"]}/resume', {})
    renewed = latest(client, queued, "awaitingPermission")
    require(renewed["requiresFreshApproval"], "Resume could reuse an unattended approval")
    allowance(target, queued)
    step = next_step(target, queued, "observe")
    client.post(f'{BASE}/runs/{queued["id"]}/stop', {})
    receipt(target, queued, step, observe(), status=409)
    target.request("GET", f'{BASE}/runs/{queued["id"]}/commands/{step["id"]}', status=409)
    print("PASS Computer Use background policy, renewed grants, stop and stale receipts")

    restart = client.post(BASE + "/runs", {**base, "id": token(), "includeImages": False})
    allowance(target, restart)
    step = next_step(target, restart, "observe")
    server.stop()
    server.start()
    latest(client, restart, "interrupted")
    receipt(target, restart, step, observe(), status=409)
    require(target.post(BASE + "/next", {}).get("command") is None, "Restart replayed a claimed desktop action")
    print("PASS Computer Use restart recovery without replay")

    attachment = observe(value=RAW_ATTACHMENT, include_image=True)
    state = client.post(f"/threads/{thread}/messages", {"text": "What is in this window?", "computerObservation": attachment})
    require(find(find(state["threads"], id=thread)["messages"], text="What is in this window?")["hasComputerObservation"],
            "The chat attachment was not visible in history")
    fixtures["wait_for_reply"](client, thread, "Analyzed the one-time window.")
    with sqlite3.connect(server.data / "aides.sqlite3") as db:
        payload = db.execute("SELECT payload FROM state WHERE id = 1").fetchone()[0]
    require(RAW_OBSERVATION.encode() not in payload and RAW_ATTACHMENT.encode() not in payload and JPEG.encode() not in payload,
            "Captured window content persisted to disk")
    print("PASS one-shot local visual chat attachment and observation privacy")


def main():
    with tempfile.TemporaryDirectory(prefix="aides-computer-smoke-") as folder:
        server = IsolatedServer(Path(sys.argv[1]).resolve(), Path(folder))
        with ThreadingHTTPServer(("127.0.0.1", 0), ModelFixture) as model:
            worker = threading.Thread(target=model.serve_forever, daemon=True)
            worker.start()
            try:
                exercise(server, model)
            finally:
                server.stop()
                model.shutdown()
                worker.join()


if __name__ == "__main__":
    main()
