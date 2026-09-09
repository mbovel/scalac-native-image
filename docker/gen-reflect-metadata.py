#!/usr/bin/env python3
"""Register every class on the compiler classpath for reflection.

Needed only for the macro-enabled image. With -H:+RuntimeClassLoading the macro
class loader is a real URLClassLoader delegating to its parent, but a built-in
class is only resolvable *by name* if it was registered: without this,
Class.forName("scala.quoted.Quotes") throws CNFE inside the image, delegation
falls through, the loader defines a second copy of Quotes from the jar, and
macro expansion dies with AbstractMethodError.

Usage: gen-reflect-metadata.py <cp-dir> <agent-config-dir> <out-dir>
"""
import json
import os
import sys
import zipfile

cp_dir, agent_dir, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]

names = set()
for root, _, files in os.walk(cp_dir):
    for f in sorted(files):
        if not f.endswith(".jar"):
            continue
        with zipfile.ZipFile(os.path.join(root, f)) as z:
            for n in z.namelist():
                if n.endswith(".class") and not n.startswith("META-INF"):
                    names.add(n[:-len(".class")].replace("/", "."))

agent_file = os.path.join(agent_dir, "reachability-metadata.json")
meta = json.load(open(agent_file)) if os.path.exists(agent_file) else {}
existing = {e.get("type") for e in meta.get("reflection", []) if isinstance(e.get("type"), str)}
added = [{"type": n} for n in sorted(names) if n not in existing]
meta.setdefault("reflection", []).extend(added)

os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "reachability-metadata.json"), "w") as fh:
    json.dump(meta, fh, indent=1)

print(f"registered {len(added)} additional classes "
      f"({len(meta['reflection'])} reflection entries total)")
