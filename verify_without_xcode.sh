#!/bin/zsh
set -euo pipefail

project_root=${0:A:h}
source_root="$project_root/QuickStash"
project_file="$project_root/QuickStash.xcodeproj/project.pbxproj"
test_binary=$(mktemp /tmp/quickstash-core-tests.XXXXXX)
view_model_test_binary=$(mktemp /tmp/quickstash-view-model-tests.XXXXXX)
screenshot_test_binary=$(mktemp /tmp/quickstash-screenshot-tests.XXXXXX)
app_binary=$(mktemp /tmp/quickstash-link-check.XXXXXX)
clipboard_helper_binary=$(mktemp /tmp/quickstash-clipboard-helper.XXXXXX)
isolated_user_home=$(mktemp -d /tmp/quickstash-test-home.XXXXXX)
export CFFIXED_USER_HOME="$isolated_user_home"
export QUICKSTASH_CLIPBOARD_HELPER_PATH="$clipboard_helper_binary"
trap 'rm -f "$test_binary" "$view_model_test_binary" "$screenshot_test_binary" "$app_binary" "$clipboard_helper_binary"; rm -rf "$isolated_user_home"' EXIT

plutil -lint "$source_root/Info.plist" "$project_file"

for source_file in "$source_root"/*.swift; do
  source_name=${source_file:t}
  if ! rg -F -q "$source_name in Sources" "$project_file"; then
    print -u2 "Missing from Xcode Sources: $source_name"
    exit 1
  fi
done

rg -F -q 'Assets.xcassets in Resources' "$project_file"

app_build_phases=$(plutil -extract objects.T1.buildPhases json -o - "$project_file")
app_dependencies=$(plutil -extract objects.T1.dependencies json -o - "$project_file")
helper_embed_files=$(plutil -extract objects.HE1.files json -o - "$project_file")
helper_embed_attributes=$(plutil -extract objects.HA2.settings.ATTRIBUTES json -o - "$project_file")
helper_sources=$(plutil -extract objects.HS1.files json -o - "$project_file")
if [[ "$app_build_phases" != *'"HE1"'* \
   || "$app_dependencies" != *'"D2"'* \
   || "$helper_embed_files" != '["HA2"]' \
   || "$helper_embed_attributes" != '["CodeSignOnCopy"]' \
   || "$helper_sources" != '["HA1"]' \
   || "$(plutil -extract objects.HE1.dstSubfolderSpec raw -o - "$project_file")" != "6" \
   || "$(plutil -extract objects.HA2.fileRef raw -o - "$project_file")" != "HC1" \
   || "$(plutil -extract objects.D2.target raw -o - "$project_file")" != "T3" \
   || "$(plutil -extract objects.T3.productReference raw -o - "$project_file")" != "HC1" \
   || "$(plutil -extract objects.T3.productType raw -o - "$project_file")" != "com.apple.product-type.tool" \
   || "$(plutil -extract objects.HA1.fileRef raw -o - "$project_file")" != "HB1" \
   || "$(plutil -extract objects.HC2.buildSettings.SKIP_INSTALL raw -o - "$project_file")" != "YES" \
   || "$(plutil -extract objects.HC3.buildSettings.SKIP_INSTALL raw -o - "$project_file")" != "YES" ]]; then
  print -u2 "Clipboard helper target dependency or embed relationship is incomplete"
  exit 1
fi

release_build_settings=$(sed -n '/C3 \/\* Release \*\//,/name = Release;/p' "$project_file")
if ! rg -F -q 'ENABLE_CODE_COVERAGE = NO;' <<< "$release_build_settings"; then
  print -u2 "Release builds must disable code coverage instrumentation"
  exit 1
fi
if ! rg -F -q 'CLANG_COVERAGE_MAPPING = NO;' <<< "$release_build_settings"; then
  print -u2 "Release builds must disable Clang coverage mapping"
  exit 1
fi
if ! rg -F -q 'ENABLE_DEBUG_DYLIB = NO;' <<< "$release_build_settings"; then
  print -u2 "Release builds must disable debug dylib injection"
  exit 1
fi
if ! rg -F -q 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;' <<< "$release_build_settings"; then
  print -u2 "Release signing must not inject development entitlements"
  exit 1
fi
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
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -strict-concurrency=complete \
  -warn-concurrency \
  -warnings-as-errors \
  "$project_root/ClipboardReaderHelper/main.swift" \
  -o "$clipboard_helper_binary"

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
  "$source_root/ClipboardPasteboardHelperClient.swift" \
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
