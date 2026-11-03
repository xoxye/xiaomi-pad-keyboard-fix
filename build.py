#!/usr/bin/env python3
import os
import time
import shutil
import zipfile

def build_zip():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    output_zips = [
        os.path.join(base_dir, "xiaomi-pad-keyboard-fix.zip"),
        os.path.join(base_dir, "magisk-xiaomi-keyboard-fix.zip")
    ]
    
    ignore_files = {".git", ".gitattributes", ".gitignore", "build.py", "xiaomi-pad-keyboard-fix.zip", "magisk-xiaomi-keyboard-fix.zip"}
    
    # We will build to the primary zip, then copy to secondary
    primary_zip = output_zips[0]
    
    with zipfile.ZipFile(primary_zip, "w", compression=zipfile.ZIP_DEFLATED) as z:
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
                
                zinfo = zipfile.ZipInfo(rel_p)
                zinfo.date_time = time.localtime(os.path.getmtime(abs_p))[:6]
                zinfo.compress_type = zipfile.ZIP_DEFLATED
                
                # Assign executable permissions 0755 to scripts and binaries
                if fn.endswith((".sh", "kb", "update-binary", "updater-script")) or "bin" in rel_p.split("/"):
                    zinfo.external_attr = 0o100755 << 16
                else:
                    zinfo.external_attr = 0o100644 << 16
                
                z.writestr(zinfo, data)
                print(f"Added: {rel_p} (mode: {'0755' if (zinfo.external_attr >> 16) == 0o100755 else '0644'})")
                
    shutil.copyfile(primary_zip, output_zips[1])
    # Also copy to parent directory if building inside repo
    parent_zip = os.path.join(os.path.dirname(base_dir), "xiaomi-pad-keyboard-fix.zip")
    try:
        shutil.copyfile(primary_zip, parent_zip)
    except Exception:
        pass
        
    print(f"\nSuccessfully created flashable Magisk module packages:")
    for oz in output_zips:
        print(f" - {oz} ({os.path.getsize(oz)} bytes)")

if __name__ == "__main__":
    build_zip()
