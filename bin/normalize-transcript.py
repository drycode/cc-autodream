#!/usr/bin/env python3
"""Stream OMP/Codex roots into the Claude-shaped transcript used by autodream."""

import argparse
import json
import sys
from pathlib import Path

LIMIT = 4000
ELISION = "…[autodream tool result elided]"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("src", type=Path)
    parser.add_argument("dest", type=Path)
    parser.add_argument("--harness", choices=("omp", "codex", "auto"), default="auto")
    args = parser.parse_args()
    harness = args.harness
    if harness == "auto":
        harness = "codex" if "rollout-" in args.src.name else "omp"
    if args.src.resolve() == args.dest.resolve():
        print("source and destination must differ", file=sys.stderr)
        return 1
    try:
        with args.src.open(encoding="utf-8") as source:
            with args.dest.open("w", encoding="utf-8") as target:
                count = _convert(source, target, args.src, harness)
        if count == 0:
            args.dest.unlink(missing_ok=True)
            return 3
        return 0
    except (OSError, UnicodeError, ValueError) as exc:
        args.dest.unlink(missing_ok=True)
        print(f"cannot normalize {args.src}: {exc}", file=sys.stderr)
        return 1


def _convert(source, target, path, harness):
    # Metadata is first even when the source records arrive in an unusual order.
    # Seek only over this file; records themselves are decoded one at a time.
    metadata = _metadata(source, path, harness)
    target.write(json.dumps(metadata, ensure_ascii=False) + "\n")
    source.seek(0)
    model = None
    turns = 0
    # An OMP fork/resume root (header carries parentSession) starts with a copy of
    # the parent's history under the original timestamps. Only turns after the
    # fork belong to this session; the parent's file is triaged on its own.
    fork_start = metadata.get("forked_at") or ""
    for line in source:
        record = json.loads(line)
        if not isinstance(record, dict):
            continue
        if harness == "omp":
            if record.get("type") == "model_change":
                model = record.get("model") or model
            if fork_start and (record.get("timestamp") or "") < fork_start:
                continue
            item = _omp_message(record, metadata["cwd"], model)
        else:
            if record.get("type") == "turn_context":
                model = record.get("payload", {}).get("model") or model
            item = _codex_message(record, metadata["cwd"], model)
        if item:
            target.write(json.dumps(item, ensure_ascii=False) + "\n")
            turns += item["type"] == "user"
    return turns


def _metadata(source, path, harness):
    meta = {"type": "autodream_source", "harness": harness,
            "source_path": str(path), "cwd": "", "session_id": ""}
    if harness == "omp" and path.parent.parent.name == "sessions":
        meta["profile"] = path.parent.parent.parent.parent.name if "profiles" in path.parts else None
        if meta["profile"] is None:
            meta.pop("profile")
    for line in source:
        record = json.loads(line)
        if not isinstance(record, dict):
            continue
        if harness == "omp" and record.get("type") == "session":
            meta.update(cwd=record.get("cwd") or "", session_id=record.get("id") or "")
            if record.get("parentSession"):
                meta.update(forked_from=record["parentSession"], forked_at=record.get("timestamp") or "")
            break
        if harness == "codex" and record.get("type") == "session_meta":
            payload = record.get("payload") or {}
            meta.update(cwd=payload.get("cwd") or "", session_id=payload.get("id") or payload.get("session_id") or "")
            break
    return meta


def _omp_message(record, cwd, model):
    if record.get("type") != "message":
        return None
    msg = record.get("message") or {}
    role = msg.get("role")
    if role not in ("user", "assistant", "toolResult"):
        return None
    content = []
    for part in msg.get("content") or []:
        if not isinstance(part, dict):
            continue
        kind = part.get("type")
        if kind == "text" and role != "toolResult":
            content.append({"type": "text", "text": part.get("text", "")})
        elif kind == "toolCall" and role == "assistant":
            content.append({"type": "tool_use", "name": part.get("name", ""), "input": part.get("arguments", part.get("input", {}))})
    if role == "toolResult":
        content = [{"type": "tool_result", "content": _bounded(msg.get("content")),
                    "is_error": bool(msg.get("isError")), "tool_use_id": msg.get("toolCallId"),
                    "tool_name": msg.get("toolName")}]
    if not content:
        return None
    return _message("user" if role == "user" else "assistant", record.get("timestamp"), cwd, msg.get("model") or model, content)


def _codex_message(record, cwd, model):
    if record.get("type") != "response_item":
        return None
    payload = record.get("payload") or {}
    kind = payload.get("type")
    role = payload.get("role")
    if kind == "message" and role in ("user", "assistant"):
        content = [{"type": "text", "text": part.get("text", "")}
                   for part in payload.get("content") or [] if isinstance(part, dict)
                   and part.get("type") in ("input_text", "output_text", "text")]
        return _message(role, record.get("timestamp"), cwd, model, content) if content else None
    if kind in ("function_call", "custom_tool_call"):
        raw = payload.get("arguments", payload.get("input", {}))
        try:
            arguments = json.loads(raw) if isinstance(raw, str) else raw
        except ValueError:
            arguments = raw
        part = {"type": "tool_use", "name": payload.get("name", ""), "input": arguments}
    elif kind in ("function_call_output", "custom_tool_call_output"):
        part = {"type": "tool_result", "content": _bounded(payload.get("output")),
                "is_error": False, "tool_use_id": payload.get("call_id")}
    else:
        return None
    return _message("assistant", record.get("timestamp"), cwd, model, [part])


def _message(role, timestamp, cwd, model, content):
    message = {"role": role, "content": content}
    if model and role == "assistant":
        message["model"] = model
    return {"type": role, "timestamp": timestamp, "cwd": cwd, "message": message}


def _bounded(value):
    if isinstance(value, str):
        text = value
    elif isinstance(value, list):
        text = "\n".join(part if isinstance(part, str) else str(part.get("text", ""))
                         if isinstance(part, dict) else str(part) for part in value)
    else:
        text = json.dumps(value, ensure_ascii=False)
    return text if len(text) <= LIMIT else text[:LIMIT] + ELISION


if __name__ == "__main__":
    sys.exit(main())
