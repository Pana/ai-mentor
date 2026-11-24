#!/usr/bin/env python3
"""Publish a Gradle-built universal APK into the gateway's Android update directory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
from tempfile import NamedTemporaryFile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("apk_directory", type=Path, help="Gradle APK output directory containing output-metadata.json")
parser.add_argument("publish_directory", type=Path, help="gateway Android update directory (or local staging directory)")
args = parser.parse_args()
metadata = json.loads((args.apk_directory / "output-metadata.json").read_text())
element, = metadata["elements"]
if metadata["applicationId"] != "cn.littlebear.tutor" or element["filters"]:
    parser.error("expected a universal LittleBear APK")
target = args.publish_directory
target.mkdir(parents=True, exist_ok=True)
with (args.apk_directory / element["outputFile"]).open("rb") as source, NamedTemporaryFile(dir=target, delete=False) as tmp:
    shutil.copyfileobj(source, tmp)
apk = Path(tmp.name)
with apk.open("rb") as source:
    digest = hashlib.sha256(source.read()).hexdigest()
manifest = dict(versionCode=element["versionCode"], versionName=element["versionName"], sha256=digest, size=apk.stat().st_size)
apk.chmod(0o644)
apk.replace(target / (digest + ".apk"))
with NamedTemporaryFile(mode="w", dir=target, delete=False) as tmp:
    json.dump(manifest, tmp)
os.chmod(tmp.name, 0o644)
os.replace(tmp.name, target / "latest.json")
print(f"Published {manifest['versionName']} ({manifest['versionCode']}) to {target}")
