#!/usr/bin/env python3
"""Patch Marzban's Telegram bot (app/telegram/handlers/admin.py, v0.8.4) so that
every config link is labelled with its remark and transport, both in the
"Links" message and in the per-config QR captions.

Usage: marzban_bot_patch.py <admin.py from the image> <patched output path>
The output is bind-mounted over /code/app/telegram/handlers/admin.py.
"""
import sys

src_path, dst_path = sys.argv[1], sys.argv[2]
src = open(src_path, encoding="utf-8").read()

HELPER = '''
from html import escape as _html_escape
from urllib.parse import parse_qs as _parse_qs, unquote as _unquote, urlsplit as _urlsplit


def _link_label(link: str) -> str:
    """Human readable header for a share link: remark + transport + port."""
    try:
        u = _urlsplit(link)
        q = _parse_qs(u.query)
        name = _unquote(u.fragment) if u.fragment else u.scheme
        net = (q.get("type") or ["tcp"])[0] or "tcp"
        flow = (q.get("flow") or [""])[0]
        sec = (q.get("security") or [""])[0]
        mode = (q.get("mode") or [""])[0]
        transport = net.upper()
        if mode:
            transport += f" {mode}"
        if flow:
            transport += " Vision"
        if sec:
            transport += f" + {sec.upper()}"
        hint = "\u26a1 fast" if flow else "\U0001f6e1 primary"
        return _html_escape(f"{name}\\n{hint} \\u00b7 {transport} \\u00b7 :{u.port}")
    except Exception:
        return _html_escape(link[:60])

'''

ANCHOR_HELPER = '@bot.callback_query_handler(cb_query_startswith("links:"), is_admin=True)'

REPLACEMENTS = [
    # "Links" message
    (
        "        text += f'\\n<code>{link}</code>'\n",
        "        text += f'\\n<b>{_link_label(link)}</b>\\n<code>{link}</code>\\n'\n",
    ),
    # QR caption per config
    (
        '                    caption=f"<code>{link}</code>",\n',
        '                    caption=f"<b>{_link_label(link)}</b>\\n<code>{link}</code>",\n',
    ),
    # Links re-sent after the QR codes
    (
        '        text += f"<code>{link}</code>\\n\\n"\n',
        '        text += f"<b>{_link_label(link)}</b>\\n<code>{link}</code>\\n\\n"\n',
    ),
]

if "_link_label" in src:
    print("already patched")
    open(dst_path, "w", encoding="utf-8").write(src)
    sys.exit(0)

if ANCHOR_HELPER not in src:
    sys.exit("anchor for helper not found - Marzban version mismatch")
src = src.replace(ANCHOR_HELPER, HELPER + "\n" + ANCHOR_HELPER, 1)

for old, new in REPLACEMENTS:
    if src.count(old) != 1:
        sys.exit(f"anchor not found exactly once: {old!r}")
    src = src.replace(old, new, 1)

open(dst_path, "w", encoding="utf-8").write(src)
print("patched")
