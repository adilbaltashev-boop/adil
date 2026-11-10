"""PreToolUse hook: blocks any access to .env files and secrets/ (exit code 2 = deny, stderr goes to the model)."""
import json
import re
import sys

SECRET = re.compile(r"(^|[\s/'\"=])(\.env(\.[\w.-]+)?(?=$|[\s/'\";|&)])|secrets/)")
ALLOWED = re.compile(r"\.env\.(example|sample|template)$")


def check(payload: dict) -> str | None:
    tool_input = payload.get("tool_input") or {}
    targets = [tool_input.get("file_path") or "", tool_input.get("command") or ""]
    for text in targets:
        for m in SECRET.finditer(text):
            if not ALLOWED.search(m.group(2)):
                return f"Доступ к секретам запрещён ({m.group(2)}). Секреты читаются только из переменных окружения."
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0
    reason = check(payload)
    if reason:
        print(reason, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
