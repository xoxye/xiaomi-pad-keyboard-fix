import os
import time
import shutil
import zipfile

def build_zip():
    repo_dir = r"d:\magiskdev\magisk-xiaomi-keyboard-fix"
    zip_path = r"d:\magiskdev\xiaomi-pad-keyboard-fix.zip"
    alt_zip_path = r"d:\magiskdev\magisk-xiaomi-keyboard-fix.zip"
    
    print(f"Building {zip_path} from {repo_dir}...")
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(repo_dir):
            if ".git" in root.split(os.sep) or "src" in root.split(os.sep):
                continue
            for f in sorted(files):
                if f.endswith(".zip") or f.endswith(".c") or f in {".git", ".gitattributes", ".gitignore", "build.py"}:
                    continue
                abs_p = os.path.join(root, f)
                rel_p = os.path.relpath(abs_p, repo_dir).replace("\\", "/")
                with open(abs_p, "rb") as fp:
                    data = fp.read()
                # Ensure LF endings on text/script files
                if f.endswith((".sh", ".prop", "kb", ".md", ".txt", ".xml", "update-binary", "updater-script")):
                    data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
                
                zinfo = zipfile.ZipInfo(rel_p)
                zinfo.date_time = time.localtime(os.path.getmtime(abs_p))[:6]
                zinfo.compress_type = zipfile.ZIP_DEFLATED
                
                # Assign 0755 permissions to executables and scripts
                if f.endswith((".sh", "kb", "update-binary", "updater-script")) or "bin" in rel_p.split("/"):
                    zinfo.external_attr = 0o100755 << 16
                else:
                    zinfo.external_attr = 0o100644 << 16
                
                z.writestr(zinfo, data)
                print(f"  Added: {rel_p} ({len(data)} bytes, mode: {'0755' if (zinfo.external_attr >> 16) == 0o100755 else '0644'})")
                
    shutil.copyfile(zip_path, alt_zip_path)
    # Also keep synced in repo folder
    shutil.copyfile(zip_path, os.path.join(repo_dir, "xiaomi-pad-keyboard-fix.zip"))
    shutil.copyfile(zip_path, os.path.join(repo_dir, "magisk-xiaomi-keyboard-fix.zip"))
    print(f"\nSuccessfully built {zip_path}: {os.path.getsize(zip_path)} bytes")

if __name__ == "__main__":
    build_zip()
