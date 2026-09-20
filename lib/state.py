#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# proxy-node-audit / state.py
# 极简 JSON 状态库：把各阶段结果合并进单个 state.json，便于后续评分与报告。
#
# 用法:
#   state.py init                <state.json>
#   state.py set <key> <json|文字> <state.json>
#   state.py set-file <key> <file.json> <state.json>
#   state.py append <key> <file.json|ndjson> <state.json>
#   state.py get <key> <state.json>
# ---------------------------------------------------------------------------
import json
import os
import sys
import tempfile

FORBIDDEN_KEYS = {"set", "init", "append", "get", "set-file"}


def load(path):
    if not path or not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (ValueError, OSError):
        return {}


def save(path, data):
    directory = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def coerce(raw):
    """尽力把字符串解释为 JSON，失败则当作字符串。"""
    raw = raw.strip()
    if not raw:
        return raw
    try:
        return json.loads(raw)
    except ValueError:
        return raw


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[0]

    if cmd == "init":
        path = argv[1]
        data = load(path)
        data.setdefault("state_version", 1)
        save(path, data)
        return 0

    if cmd == "set":
        if len(argv) < 4:
            print("set 需要 <key> <value> <state>", file=sys.stderr)
            return 2
        key, value, path = argv[1], argv[2], argv[3]
        data = load(path)
        data[key] = coerce(value)
        save(path, data)
        return 0

    if cmd == "set-file":
        if len(argv) < 4:
            print("set-file 需要 <key> <file> <state>", file=sys.stderr)
            return 2
        key, src, path = argv[1], argv[2], argv[3]
        with open(src, "r", encoding="utf-8") as fh:
            content = fh.read()
        data = load(path)
        data[key] = coerce(content)
        save(path, data)
        return 0

    if cmd == "append":
        if len(argv) < 4:
            print("append 需要 <key> <file> <state>", file=sys.stderr)
            return 2
        key, src, path = argv[1], argv[2], argv[3]
        with open(src, "r", encoding="utf-8") as fh:
            content = fh.read().strip()
        data = load(path)
        bucket = data.get(key)
        if not isinstance(bucket, list):
            bucket = []
        if not content:
            data[key] = bucket
            save(path, data)
            return 0
        try:
            parsed = json.loads(content)
            items = parsed if isinstance(parsed, list) else [parsed]
        except ValueError:
            items = [json.loads(line) for line in content.splitlines() if line.strip()]
        bucket.extend(items)
        data[key] = bucket
        save(path, data)
        return 0

    if cmd == "get":
        if len(argv) < 3:
            print("get 需要 <key> <state>", file=sys.stderr)
            return 2
        key, path = argv[1], argv[2]
        data = load(path)
        if key not in data:
            return 1
        value = data[key]
        if isinstance(value, str):
            print(value)
        else:
            print(json.dumps(value, ensure_ascii=False, indent=2))
        return 0

    print(f"未知命令: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
