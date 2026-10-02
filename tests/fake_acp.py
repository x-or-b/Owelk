#!/usr/bin/env python3
"""A stand-in ACP agent (JSON-RPC over stdio, one JSON per line) for Owelk's agent tests."""
import json
import os
import sys

signed_in = os.environ.get("FAKE_ACP_SIGNED_IN") == "1"
model = "fast"
mode = "agent"
sessions = 0
pending = {}  # our request id -> session waiting on a permission answer
next_id = 1000


def send(message):
    message["jsonrpc"] = "2.0"
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def config():
    return [{"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": mode,
             "options": [{"value": "read-only", "name": "Read-only"}, {"value": "agent", "name": "Auto"}]},
            {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": model,
             "options": [{"value": "fast", "name": "Fast"},
                         {"group": "big", "name": "Large", "options": [{"value": "deep", "name": "Deep"}]}]}]


for line in sys.stdin:
    message = json.loads(line)
    method, request_id, params = message.get("method"), message.get("id"), message.get("params") or {}
    if method == "initialize":
        caps = params.get("clientCapabilities", {})
        # Owelk must not offer file access or a terminal.
        assert caps.get("terminal") is False and caps["fs"]["writeTextFile"] is False, caps
        send({"id": request_id, "result": {"protocolVersion": 1,
              "agentCapabilities": {"promptCapabilities": {"image": True}},
              "authMethods": [{"id": "browser", "name": "Sign in with browser"},
                              {"id": "tty", "name": "Terminal", "type": "terminal"}]}})
    elif method == "authenticate":
        signed_in = params.get("methodId") == "browser"
        send({"id": request_id, "result": {}})
    elif method == "session/new":
        if not signed_in:
            send({"id": request_id, "error": {"code": -32000, "message": "Authentication required"}})
            continue
        sessions += 1
        send({"id": request_id, "result": {"sessionId": "s%d" % sessions, "configOptions": config()}})
    elif method == "session/set_config_option":
        if params["configId"] == "mode":
            mode = params["value"]
        else:
            model = params["value"]
        send({"id": request_id, "result": {"configOptions": config()}})
    elif method == "session/prompt":
        session = params["sessionId"]
        text = params["prompt"][0]["text"]
        # Ask to run a tool first; Owelk has to decline.
        next_id += 1
        pending[next_id] = (request_id, session, text)
        send({"id": next_id, "method": "session/request_permission", "params": {
            "sessionId": session, "toolCall": {"toolCallId": "t1", "title": "Write file"},
            "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"},
                        {"optionId": "no", "name": "Reject", "kind": "reject_once"}]}})
    elif method == "session/cancel":
        pass
    elif request_id in pending and method is None:
        prompt_id, session, text = pending.pop(request_id)
        outcome = message.get("result", {}).get("outcome", {})
        declined = outcome.get("outcome") == "selected" and outcome.get("optionId") == "no"
        reply = ("declined" if declined else "ALLOWED") + ("" if mode == "read-only" else " NOT READ-ONLY")
        has_history = "Earlier in this conversation" in text
        for piece in ["Agent ", "answer ", "(%s, %s%s)" % (reply, model, ", history" if has_history else "")]:
            send({"method": "session/update", "params": {"sessionId": session, "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": piece}}}})
        send({"id": prompt_id, "result": {"stopReason": "end_turn"}})
    elif request_id is not None and method is not None:
        send({"id": request_id, "error": {"code": -32601, "message": "unknown " + method}})
