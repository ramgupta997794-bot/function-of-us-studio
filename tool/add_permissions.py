"""Prepare the Android project for the build:

  * add the permissions the app needs,
  * bump minSdkVersion to 24 (required by ffmpeg-kit), and
  * pin ndkVersion to an NDK that is already installed on the CI runner, so
    Gradle does not try to download one (that download is flaky and has been
    observed to fail with "Error on ZipFile unknown archive").

Run by the CI workflow and by build_apk.sh. Safe to run more than once.
"""
import pathlib
import re

NDK_VERSION = "27.3.13750724"


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


def pin_ndk(version: str = NDK_VERSION) -> None:
    for name in ("android/app/build.gradle.kts", "android/app/build.gradle"):
        p = pathlib.Path(name)
        if not p.exists():
            continue
        s = p.read_text()
        out = s
        if name.endswith(".kts"):
            if re.search(r"ndkVersion\s*=", out):
                out = re.sub(r"ndkVersion\s*=\s*[^\n]+", f'ndkVersion = "{version}"', out)
            elif "ndkVersion" in out:
                out = re.sub(r"ndkVersion\s+[^\n]+", f'ndkVersion = "{version}"', out)
            else:
                out = out.replace("android {", f'android {{\n    ndkVersion = "{version}"', 1)
        else:
            if re.search(r"ndkVersion\s+", out):
                out = re.sub(r"ndkVersion\s+[^\n]+", f'ndkVersion "{version}"', out)
            else:
                out = out.replace("android {", f'android {{\n    ndkVersion "{version}"', 1)
        if out != s:
            p.write_text(out)
            print(f"ndkVersion pinned to {version} in {name}")
        else:
            print(f"ndkVersion unchanged in {name}")


if __name__ == "__main__":
    add_permissions()
    bump_min_sdk(24)
    pin_ndk(NDK_VERSION)
