#!/usr/bin/env bash
# Local APK build for Function of Us Studio.
# Requires: Flutter SDK (>=3.19), Android SDK, Java 17.
set -euo pipefail

echo "==> Backing up lib/main.dart"
cp lib/main.dart /tmp/main.dart.bak

echo "==> Scaffolding platform folders"
flutter create --org com.functionofus --project-name function_of_us_studio .

echo "==> Restoring lib/main.dart"
cp /tmp/main.dart.bak lib/main.dart

echo "==> Adding Android permissions"
python3 tool/add_permissions.py

echo "==> Fetching packages"
flutter pub get

echo "==> Building release APK"
flutter build apk --release --split-per-abi

echo
echo "Done. APKs:"
ls -1 build/app/outputs/flutter-apk/*.apk
