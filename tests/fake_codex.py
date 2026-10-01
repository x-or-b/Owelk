#!/usr/bin/env python3
"""A stand-in for `codex app-server` speaking the JSON-RPC subset Owelk uses (stdio, one JSON per line)."""
import json
import sys

signed_in = False


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    message = json.loads(line)
    method, request_id, params = message.get("method"), message.get("id"), message.get("params") or {}
    if method == "initialize":
        send({"id": request_id, "result": {"userAgent": "fake"}})
    elif method == "initialized":
        pass
    elif method == "account/read":
        account = {"type": "chatgpt", "email": "reader@example.com", "planType": "plus"} if signed_in else None
        send({"id": request_id, "result": {"account": account, "requiresOpenaiAuth": True}})
    elif method == "account/login/start":
        signed_in = True
        send({"id": request_id, "result": {"type": "chatgpt", "loginId": "l1", "authUrl": "https://auth.example.com/login"}})
        send({"method": "account/login/completed", "params": {"loginId": "l1", "success": True}})
    elif method == "account/logout":
        signed_in = False
        send({"id": request_id, "result": {}})
    elif method == "model/list":
        send({"id": request_id, "result": {"data": [
            {"id": "m1", "model": "gpt-test", "displayName": "GPT Test", "hidden": False, "isDefault": True},
            {"id": "m2", "model": "gpt-hidden", "displayName": "Hidden", "hidden": True, "isDefault": False}]}})
    elif method == "thread/start":
        # Owelk must ask for a throwaway, read-only thread that never runs commands.
        ok = params.get("ephemeral") is True and params.get("sandbox") == "read-only" and params.get("approvalPolicy") == "never"
        send({"id": request_id, "result": {"thread": {"id": "t1" if ok else "unsafe"}, "model": "gpt-test"}})
    elif method == "turn/start":
        thread = params["threadId"]
        text = params["input"][0]["text"]
        send({"id": request_id, "result": {"turn": {"id": "u1", "status": "inProgress", "items": []}}})
        # A server request Owelk must decline without hanging.
        send({"id": 900, "method": "item/commandExecution/requestApproval", "params": {"threadId": thread}})
        for piece in ["Codex ", "answer"]:
            send({"method": "item/agentMessage/delta", "params": {"threadId": thread, "turnId": "u1", "itemId": "i1", "delta": piece}})
        status = "completed" if thread == "t1" and "selection" in text else "failed"
        send({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "u1", "status": status, "items": [],
              "error": None if status == "completed" else {"message": "unexpected request"}}}})
    elif request_id is not None and method is None:
        pass  # Owelk's reply to our approval request.
    elif request_id is not None:
        send({"id": request_id, "error": {"code": -32601, "message": "unknown " + str(method)}})
