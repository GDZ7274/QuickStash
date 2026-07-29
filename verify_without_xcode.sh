#!/bin/zsh
set -euo pipefail

project_root=${0:A:h}
source_root="$project_root/QuickStash"
test_binary=$(mktemp /tmp/quickstash-core-tests.XXXXXX)
view_model_test_binary=$(mktemp /tmp/quickstash-view-model-tests.XXXXXX)
screenshot_test_binary=$(mktemp /tmp/quickstash-screenshot-tests.XXXXXX)
app_binary=$(mktemp /tmp/quickstash-link-check.XXXXXX)
isolated_user_home=$(mktemp -d /tmp/quickstash-test-home.XXXXXX)
export CFFIXED_USER_HOME="$isolated_user_home"
trap 'rm -f "$test_binary" "$view_model_test_binary" "$screenshot_test_binary" "$app_binary"; rm -rf "$isolated_user_home"' EXIT

plutil -lint "$source_root/Info.plist" "$project_root/QuickStash.xcodeproj/project.pbxproj"

for source_file in "$source_root"/*.swift; do
  source_name=${source_file:t}
  if ! rg -F -q "$source_name in Sources" "$project_root/QuickStash.xcodeproj/project.pbxproj"; then
    print -u2 "Missing from Xcode Sources: $source_name"
    exit 1
  fi
done

rg -F -q 'Assets.xcassets in Resources' "$project_root/QuickStash.xcodeproj/project.pbxproj"
rg -F -q '.leftMouseDragged' "$source_root/QuickStashApp.swift"
rg -F -q 'lazy var viewModel = StashViewModel.shared' "$source_root/QuickStashApp.swift"
if rg -F -q 'NSPasteboard(name: .drag)' "$source_root/QuickStashApp.swift"; then
  print -u2 "Global drag proximity detection must not read the drag pasteboard"
  exit 1
fi
if rg -q 'fileManager\.isManagedFile\(at:' "$source_root/StashViewModel.swift"; then
  print -u2 "MainActor must not resolve managed paths synchronously"
  exit 1
fi
if rg -q 'func flushSynchronously\(' "$source_root/StashViewModel.swift"; then
  print -u2 "MainActor must not expose synchronous persistence I/O"
  exit 1
fi
rg -F -q 'pendingTemporaryURL' "$source_root/ScreenshotCoordinator.swift"
rg -F -q 'guard !Task.isCancelled else' "$source_root/ScreenshotCoordinator.swift"
rg -F -q 'quickStashOwnsHotKeyID(hotKeyID)' "$source_root/ScreenshotHotKey.swift"
rg -F -q 'ImportPolicy.default.maximumSourceItems + 1' "$source_root/DragDropSupport.swift"

source_files=("$source_root"/*.swift)
xcrun swiftc \
  -typecheck \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -strict-concurrency=complete \
  -warn-concurrency \
  -warnings-as-errors \
  "${source_files[@]}"

xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  "${source_files[@]}" \
  -o "$app_binary"

xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -strict-concurrency=complete \
  -warn-concurrency \
  -warnings-as-errors \
  "$source_root/Models.swift" \
  "$source_root/FileManager+QuickStash.swift" \
  "$source_root/StorageManager.swift" \
  "$project_root/Tests/QuickStashCoreTests.swift" \
  -o "$test_binary"

"$test_binary"

xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -strict-concurrency=complete \
  -warn-concurrency \
  -warnings-as-errors \
  "$source_root/Models.swift" \
  "$source_root/FileManager+QuickStash.swift" \
  "$source_root/StorageManager.swift" \
  "$source_root/ClipboardMonitor.swift" \
  "$source_root/StashViewModel.swift" \
  "$project_root/Tests/QuickStashViewModelTests.swift" \
  -o "$view_model_test_binary"

"$view_model_test_binary"

xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -strict-concurrency=complete \
  -warn-concurrency \
  -warnings-as-errors \
  "$source_root/Models.swift" \
  "$source_root/FileManager+QuickStash.swift" \
  "$source_root/DragDropSupport.swift" \
  "$source_root/ScreenshotModels.swift" \
  "$source_root/ScreenshotHotKey.swift" \
  "$source_root/ScreenshotRenderer.swift" \
  "$project_root/Tests/QuickStashScreenshotTests.swift" \
  -o "$screenshot_test_binary"

"$screenshot_test_binary"
