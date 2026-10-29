#!/usr/bin/env python3 -I
"""Edit one key of the *staging* Nook's settings (testing only). Quit Nook Staging first.
Goes through `defaults`, so the preferences daemon stays consistent.
usage: set-staging-setting.py <key> <json-value>|--delete"""
import json, plistlib, subprocess, sys, os
domain = os.path.expanduser("~/Library/Containers/dev.local.nook.staging/Data/Library/Preferences/dev.local.nook.staging")
exported = subprocess.run(["defaults", "export", domain, "-"], capture_output=True).stdout
plist = plistlib.loads(exported) if exported else {}
settings = json.loads(plist.get("settings.v1", b"{}"))
if sys.argv[2] == "--delete":
    settings.pop(sys.argv[1], None)
else:
    settings[sys.argv[1]] = json.loads(sys.argv[2])
plist["settings.v1"] = json.dumps(settings).encode()
subprocess.run(["defaults", "import", domain, "-"], input=plistlib.dumps(plist), check=True)
print(f"{sys.argv[1]} -> {settings.get(sys.argv[1], '(default)')}")
