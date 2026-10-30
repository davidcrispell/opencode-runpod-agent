"""Verify a deployed harness with real model-generated tools; no provider mocks."""

import argparse
import base64
import json
import time
import urllib.error
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--access-file", type=Path, required=True,
                    help="Private JSON file with pod_id, password, and model_key")
parser.add_argument("--model", default="qwen3-4b")
parser.add_argument("--timeout", type=int, default=300)
args = parser.parse_args()
access = json.loads(args.access_file.read_text())
base = "https://" + access["pod_id"] + "-4096.proxy.runpod.net"
authorization = "Basic " + base64.b64encode(("opencode:" + access["password"]).encode()).decode()


def request(path, data=None, raw=False, anonymous=False):
    headers = {"x-opencode-directory": "/workspace/agent", "User-Agent": "RunpodHarness/1.0"}
    if not anonymous:
        headers["Authorization"] = authorization
    if data is not None:
        headers["Content-Type"] = "application/json"
    body = None if data is None else json.dumps(data).encode()
    with urllib.request.urlopen(urllib.request.Request(base + path, data=body, headers=headers), timeout=45) as response:
        content = response.read().decode()
    return content if raw else json.loads(content)


try:
    request("/api/model", anonymous=True)
    raise RuntimeError("Agent API unexpectedly allowed unauthenticated access")
except urllib.error.HTTPError as error:
    if error.code != 401:
        raise
print("PASS: agent API rejects unauthenticated requests", flush=True)

session = request("/api/session", {
    "title": "Runpod harness smoke test",
    "agent": "build",
    "location": {"directory": "/workspace/agent"},
    "model": {"providerID": "runpod-local", "id": args.model},
})["data"]["id"]
print("Session: " + session, flush=True)
evidence = {"session": session, "turns": []}
previous_ids = set()

for marker, instruction in [
    ("HARNESS_SMOKE_1", "Create harness_smoke.py containing a Python program that prints HARNESS_SMOKE_1."),
    ("HARNESS_SMOKE_2", "Edit the existing harness_smoke.py so it prints HARNESS_SMOKE_2 instead."),
]:
    admitted = request("/api/session/" + session + "/prompt", {
        "text": instruction + " Use your file or shell tools to do the work, run python3 harness_smoke.py, and report the actual stdout. Do not just describe commands."
    })["data"]["id"]
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        messages = request("/api/session/" + session + "/message?order=desc&limit=100")["data"]
        new = [message for message in messages if message["id"] not in previous_ids]
        idle = [message for message in new if message["type"] == "idle"]
        if idle:
            if idle[0]["outcome"] != "succeeded":
                raise RuntimeError("Agent failed: " + json.dumps(new))
            break
        permissions = request("/api/session/" + session + "/permission")["data"]
        if permissions:
            raise RuntimeError("Smoke test needs permission: " + json.dumps(permissions))
        time.sleep(2)
    else:
        raise TimeoutError("Agent did not complete the smoke test turn")
    tools = [part for message in new if message["type"] == "assistant"
             for part in message.get("content", []) if part["type"] == "tool"]
    if not tools:
        raise RuntimeError("Agent returned without using tools")
    executions = [tool for tool in tools if tool["name"] == "shell"
                  and tool["state"]["status"] == "completed"
                  and tool["state"].get("metadata", {}).get("exit") == 0
                  and "python3 harness_smoke.py" in json.dumps(tool["state"].get("input", {}))]
    if not executions:
        raise RuntimeError("Agent did not execute the Python program: " + json.dumps(tools))
    outputs = "\n".join(part.get("text", "") for tool in executions
                        for part in tool.get("state", {}).get("content", []))
    source = request("/api/fs/read/harness_smoke.py", raw=True)
    if marker not in source or marker not in outputs:
        raise RuntimeError("File or tool stdout missing expected marker: " + json.dumps({"source": source, "tools": tools}))
    evidence["turns"].append({"admitted": admitted, "marker": marker, "tools": tools, "source": source})
    previous_ids = {message["id"] for message in messages}
    print("PASS: " + marker + " found in the real file and tool output", flush=True)

result = args.access_file.with_name("smoke-result.json")
result.write_text(json.dumps(evidence, indent=2) + "\n")
print("Evidence: " + str(result), flush=True)
