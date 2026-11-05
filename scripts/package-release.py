#!/usr/bin/env python3
"""Package an already-built debug APK and an allowlisted, credential-free source snapshot."""
from pathlib import Path
import hashlib
import json
import re
import shutil
import tarfile

root = Path(__file__).resolve().parents[1]
config = (root / "app/build.gradle.kts").read_text()
version = re.search(r'versionName\s*=\s*"([a-zA-Z0-9.\-]+)"', config).group(1)
metadata = json.loads((root / "app/build/outputs/apk/debug/output-metadata.json").read_text())
if metadata["elements"][0]["versionName"] != version:
    raise SystemExit("APK version does not match source; rebuild first")
out = root / "artifacts"
out.mkdir(exist_ok=True)
apk = out / f"littlebear-{version}-debug.apk"
shutil.copyfile(root / "app/build/outputs/apk/debug/app-debug.apk", apk)
source = out / f"littlebear-source-{version}.tar.gz"
entries = [".gitignore", "README.md", "build.gradle.kts", "settings.gradle.kts", "gradle.properties",
           "gradlew", "gradlew.bat", "gradle", "app/build.gradle.kts", "app/src", "ipad", "docs", "scripts",
           "server/package.json", "server/.env.example", "server/README.md", "server/src", "server/test"]
with tarfile.open(source, "w:gz") as archive:
    for entry in entries:
        archive.add(root / entry, arcname="littlebear-tutor/" + entry,
                    filter=lambda info: None if "__pycache__" in Path(info.name).parts else info)
with tarfile.open(source) as archive:
    for member in archive.getmembers():
        relative = Path(member.name).relative_to("littlebear-tutor")
        if relative.name == ".env" or relative.suffix == ".keystore" or ".tooling" in relative.parts:
            raise SystemExit("Unexpected private file in source archive")
        if member.isfile():
            if archive.extractfile(member).read() != (root / relative).read_bytes():
                raise SystemExit("Source changed while packaging; run again")
    if not archive.getmember("littlebear-tutor/gradlew").mode & 0o111:
        raise SystemExit("Gradle wrapper must be executable")
lines = []
for path in [apk, source]:
    lines.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}")
    print(f"{path.name}: {path.stat().st_size:,} bytes")
(out / f"SHA256SUMS-{version}").write_text("\n".join(lines) + "\n")
