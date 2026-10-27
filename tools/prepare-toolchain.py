"""Use a local copy only when CLT ships a stale private ManifestAPI interface."""
from pathlib import Path
import shutil
import subprocess
import sys

build = Path(sys.argv[1]).resolve()
developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
pm = developer / "usr/lib/swift/pm"
if not pm.exists():
    pm = developer / "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm"
module = pm / "ManifestAPI/PackageDescription.swiftmodule"
public = module / "arm64-apple-macos.swiftinterface"
private = module / "arm64-apple-macos.private.swiftinterface"
if public.exists() and private.exists() and "swiftLanguageModes" in public.read_text() and "swiftLanguageModes" not in private.read_text():
    destination = build / "swiftpm-runtime"
    shutil.copytree(pm / "ManifestAPI", destination / "ManifestAPI", dirs_exist_ok=True)
    for module in (destination / "ManifestAPI").glob("*.swiftmodule"):
        for binary in module.glob("*.swiftmodule"):
            if binary.is_file():
                binary.unlink()
        for old in module.glob("*.private.swiftinterface"):
            matching = module / old.name.replace(".private.swiftinterface", ".swiftinterface")
            if matching.exists():
                shutil.copy2(matching, old)
    print(destination)
