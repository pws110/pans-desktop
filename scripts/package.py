#!/usr/bin/env python3
"""Package only a clean application folder, with UTF-8 paths and Unix modes."""
import pathlib
import stat
import sys
import zipfile

runtime = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2]).resolve()
allowed = {"Pan's Desktop.app", "LICENSE.txt", "先读我.txt", "先读我.md", "ReadMe-English.md"}
if {entry.name for entry in runtime.iterdir()} - allowed:
    raise SystemExit("Refusing to package a folder containing runtime/user data.")
if runtime.is_symlink() or not (runtime / "Pan's Desktop.app/Contents/MacOS/PansDesktop").is_file():
    raise SystemExit("Not a clean application folder.")
entries = [runtime] + sorted(runtime.rglob("*"))
if any(entry.is_symlink() for entry in entries):
    raise SystemExit("Unexpected symbolic link in application package.")
with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for entry in entries:
        name = entry.relative_to(runtime.parent).as_posix()
        if entry.is_dir():
            name += "/"
        info = zipfile.ZipInfo.from_file(entry, arcname=name)
        info.create_system = 3
        info.external_attr = (entry.stat().st_mode & 0xFFFF) << 16
        if entry.is_dir():
            info.external_attr |= 0x10
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, b"" if entry.is_dir() else entry.read_bytes())
print(output)
