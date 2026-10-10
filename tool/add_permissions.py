"""Prepare the Android project for the build:
  * add the permissions the app needs, and
  * bump minSdkVersion to 24 (required by ffmpeg-kit).

Run by the CI workflow and by build_apk.sh. Safe to run more than once.
"""
import pathlib
import re


def add_permissions() -> None:
    manifest = pathlib.Path("android/app/src/main/AndroidManifest.xml")
    if not manifest.exists():
        raise SystemExit("AndroidManifest.xml not found - run 'flutter create .' first")
    src = manifest.read_text()
    if "READ_MEDIA_VIDEO" in src:
        print("Permissions already present.")
        return
    perms = [
        '<uses-permission android:name="android.permission.INTERNET"/>',
        '<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>',
        '<uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>',
    ]
    src = src.replace("<application", "\n    ".join(perms) + "\n    <application", 1)
    manifest.write_text(src)
    print("Permissions added.")


def bump_min_sdk(target: int = 24) -> None:
    for name in ("android/app/build.gradle.kts", "android/app/build.gradle"):
        p = pathlib.Path(name)
        if not p.exists():
            continue
        s = p.read_text()
        out = s
        out = re.sub(r"minSdkVersion\s+flutter\.minSdkVersion", f"minSdkVersion {target}", out)
        out = re.sub(r"minSdkVersion\s+\d+", f"minSdkVersion {target}", out)
        out = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", f"minSdk = {target}", out)
        out = re.sub(r"minSdk\s*=\s*\d+", f"minSdk = {target}", out)
        if out != s:
            p.write_text(out)
            print(f"minSdk set to {target} in {name}")
        else:
            print(f"minSdk already ok (or not found) in {name}")


if __name__ == "__main__":
    add_permissions()
    bump_min_sdk(24)
