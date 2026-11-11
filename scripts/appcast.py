#!/usr/bin/python3 -I
"""Writes a Sparkle appcast with a new version first, keeping the items of the previous one.

    scripts/appcast.py --previous old.xml --out appcast.xml --version 0.5.0 --build 500 \
        --notes "One line" --url https://…/diVoice.dmg --signature 'sparkle:edSignature="…" length="…"'

The previous appcast may be empty or missing (first release). An item for the same build
number is replaced, so a failed release can be retried.
"""
import argparse
import email.utils
import html
import re
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--previous", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--version", required=True)
parser.add_argument("--build", required=True)
parser.add_argument("--notes", required=True)
parser.add_argument("--url", required=True)
parser.add_argument("--signature", required=True, help="the attributes printed by Sparkle's sign_update")
parser.add_argument("--minimum-system", default="14.0")
args = parser.parse_args()

if not re.fullmatch(r'sparkle:edSignature="[A-Za-z0-9+/=]+" length="\d+"', args.signature.strip()):
    sys.exit(f"unexpected signature attributes: {args.signature!r}")

try:
    previous = open(args.previous, encoding="utf-8").read()
except OSError:
    previous = ""
items = re.findall(r"<item>.*?</item>", previous, re.S)
build_tag = re.compile(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>")
items = [item for item in items if (m := build_tag.search(item)) is None or m.group(1) != args.build]

notes = html.escape(args.notes, quote=False)
item = f"""<item>
      <title>diVoice {html.escape(args.version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{args.build}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{args.minimum_system}</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>{notes}</p>]]></description>
      <enclosure url="{html.escape(args.url)}" type="application/octet-stream" {args.signature.strip()} />
    </item>"""

body = "\n    ".join([item] + items)
appcast = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>diVoice</title>
    {body}
  </channel>
</rss>
"""
open(args.out, "w", encoding="utf-8").write(appcast)
print(f"{args.out}: {1 + len(items)} version(s)")
