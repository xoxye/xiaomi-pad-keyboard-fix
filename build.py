#!/usr/bin/env python3
import os
import zipfile

def build_zip():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    output_zip = os.path.join(base_dir, "magisk-xiaomi-keyboard-fix.zip")
    
    ignore_files = {".git", ".gitattributes", ".gitignore", "build.py", "magisk-xiaomi-keyboard-fix.zip"}
    
    with zipfile.ZipFile(output_zip, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(base_dir):
            if ".git" in root.split(os.sep):
                continue
            for fn in files:
                if fn in ignore_files or fn.endswith(".zip"):
                    continue
                abs_p = os.path.join(root, fn)
                rel_p = os.path.relpath(abs_p, base_dir).replace("\\", "/")
                with open(abs_p, "rb") as f:
                    data = f.read()
                if fn.endswith((".sh", ".prop", "kb", "update-binary", "updater-script")):
                    data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
                z.writestr(rel_p, data)
                print(f"Added: {rel_p}")
                
    print(f"\nSuccessfully created flashable Magisk module: {output_zip} ({os.path.getsize(output_zip)} bytes)")

if __name__ == "__main__":
    build_zip()
