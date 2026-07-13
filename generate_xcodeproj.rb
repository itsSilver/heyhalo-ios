#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates apps/HaloiOS/HaloiOS.xcodeproj from the Swift sources + resources
# already on disk. Idempotent: deletes any prior project and rebuilds it, so
# this script is the source of truth for the project layout (re-run after
# adding files). Uses the xcodeproj gem (1.27.0).
#
# Targets:
#   - HaloiOS                 — the app (everything under Sources/)
#   - HaloiOSWidgetsExtension — WidgetKit/Live Activity extension (WidgetSources/),
#                               embedded in the app. Shares a few source files
#                               with the app (the Live Activity attributes + the
#                               HaloLogo mark) via SHARED_WITH_WIDGET.
#   - ReachNotificationService — Notification Service Extension
#                               (ReachNotificationService/), embedded in the app.
#                               Rewrites the Reach push body to the real reply
#                               text. See docs/specs/reach-notification-service-extension.md.
#   - HaloiOSTests            — wire-protocol round-trip tests (Tests/)
#
# Why a script and not a checked-in pbxproj: a hand-rolled pbxproj is fiddly and
# drifts; this keeps the project reproducible and reviewable.

require "xcodeproj"
require "fileutils"

ROOT = File.expand_path(__dir__)
PROJECT_PATH = File.join(ROOT, "HaloiOS.xcodeproj")
DEPLOYMENT_TARGET = "17.0"

# Forking? Point these at your own Apple team + bundle prefix without editing
# the script: set HALO_IOS_TEAM and HALO_IOS_BUNDLE_ID in your environment. You
# must also change the iCloud container in the *.entitlements files, the
# `halo://` URL scheme in Resources/Info.plist, and HaloReachKit's
# containerIdentifier to match your own container. See README.md.
BUNDLE_ID = ENV.fetch("HALO_IOS_BUNDLE_ID", "com.silvercommerce.halo.ios")
DEV_TEAM = ENV.fetch("HALO_IOS_TEAM", "A2MKDYY7R8")
WIDGET_BUNDLE_ID = "#{BUNDLE_ID}.widgets"
NSE_BUNDLE_ID = "#{BUNDLE_ID}.ReachNotificationService"

# Source files shared between the app and the widget extension (compiled into
# both targets). The Live Activity attributes + intents must be identical on
# both sides, and the widget renders the same HaloLogo mark.
SHARED_WITH_WIDGET = [
  "Sources/LiveActivity/ReachActivityAttributes.swift",
  "Sources/Branding/HaloLogo.swift",
  # The island's Approve/Skip buttons run ReachConfirmIntent, so it is compiled
  # into the widget too (Button(intent:) must resolve there). It builds the
  # answer with the shared ReachMessage wire type, which both the app and the
  # widget get by linking the HaloReachKit package (see link_package_product
  # below), so the record encoding can't drift between them.
  "Sources/LiveActivity/ReachConfirmIntent.swift",
].freeze

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)

# Collected file refs by absolute path, so shared files can be added to a second
# target without creating a duplicate ref.
file_refs = {}

def add_group_for_dir(parent_group, dir, target, file_refs)
  Dir.children(dir).sort.each do |name|
    path = File.join(dir, name)
    if File.directory?(path)
      sub = parent_group.new_group(name, path)
      add_group_for_dir(sub, path, target, file_refs)
    elsif name.end_with?(".swift")
      ref = parent_group.new_file(path)
      target.add_file_references([ref])
      file_refs[path] = ref
    end
  end
end

# ── App target ───────────────────────────────────────────────────────────────
app = project.new_target(:application, "HaloiOS", :ios, DEPLOYMENT_TARGET)

sources_group = project.main_group.new_group("Sources", File.join(ROOT, "Sources"))
add_group_for_dir(sources_group, File.join(ROOT, "Sources"), app, file_refs)

# Resources (asset catalog)
resources_group = project.main_group.new_group("Resources", File.join(ROOT, "Resources"))
assets_ref = resources_group.new_file(File.join(ROOT, "Resources", "Assets.xcassets"))
app.add_resources([assets_ref])
resources_group.new_file(File.join(ROOT, "Resources", "Info.plist"))
resources_group.new_file(File.join(ROOT, "Resources", "HaloiOS.entitlements"))
# Privacy manifest (required by App Review): declares the required-reason APIs
# the app touches (UserDefaults) and that it does no tracking. Bundled as a
# resource so it ships inside the .app.
privacy_ref = resources_group.new_file(File.join(ROOT, "Resources", "PrivacyInfo.xcprivacy"))
app.add_resources([privacy_ref])

app.build_configurations.each do |config|
  s = config.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"] = BUNDLE_ID
  s["PRODUCT_NAME"] = "HaloiOS"
  s["IPHONEOS_DEPLOYMENT_TARGET"] = DEPLOYMENT_TARGET
  s["SWIFT_VERSION"] = "6.0"
  s["SWIFT_STRICT_CONCURRENCY"] = "complete"
  s["TARGETED_DEVICE_FAMILY"] = "1" # iPhone
  s["INFOPLIST_FILE"] = "Resources/Info.plist"
  s["CODE_SIGN_ENTITLEMENTS"] = "Resources/HaloiOS.entitlements"
  # Push APNs environment, resolved into `$(APS_ENVIRONMENT)` in the
  # entitlements: a Debug (Run to device) build must be `development`, but a
  # Release/Archive build for TestFlight/App Store must be `production` or the
  # CloudKit silent push is delivered to the wrong APNs and never arrives.
  s["APS_ENVIRONMENT"] = config.name == "Release" ? "production" : "development"
  s["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  s["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] = "AccentColor"
  s["GENERATE_INFOPLIST_FILE"] = "NO"
  s["ENABLE_USER_SCRIPT_SANDBOXING"] = "YES"
  s["CURRENT_PROJECT_VERSION"] = "1"
  s["MARKETING_VERSION"] = "1.0.0"
  s["DEVELOPMENT_TEAM"] = DEV_TEAM
  s["SUPPORTS_MACCATALYST"] = "NO"
end

# ── Widget extension target (WidgetKit + Live Activity) ──────────────────────
widget = project.new_target(:app_extension, "HaloiOSWidgetsExtension", :ios, DEPLOYMENT_TARGET)
widget_group = project.main_group.new_group("WidgetSources", File.join(ROOT, "WidgetSources"))
add_group_for_dir(widget_group, File.join(ROOT, "WidgetSources"), widget, file_refs)
widget_group.new_file(File.join(ROOT, "WidgetSources", "HaloiOSWidgetsExtension.entitlements"))

# Shared sources → also compiled into the widget.
SHARED_WITH_WIDGET.each do |rel|
  ref = file_refs[File.join(ROOT, rel)]
  widget.add_file_references([ref]) if ref
end

widget.build_configurations.each do |config|
  s = config.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"] = WIDGET_BUNDLE_ID
  s["PRODUCT_NAME"] = "HaloiOSWidgetsExtension"
  s["IPHONEOS_DEPLOYMENT_TARGET"] = DEPLOYMENT_TARGET
  s["SWIFT_VERSION"] = "6.0"
  s["SWIFT_STRICT_CONCURRENCY"] = "complete"
  s["TARGETED_DEVICE_FAMILY"] = "1"
  s["INFOPLIST_FILE"] = "WidgetSources/Info.plist"
  # The island Approve/Skip intent writes CloudKit from the widget process, so
  # the widget needs its own iCloud-container entitlement (see the file).
  s["CODE_SIGN_ENTITLEMENTS"] = "WidgetSources/HaloiOSWidgetsExtension.entitlements"
  s["GENERATE_INFOPLIST_FILE"] = "NO"
  s["SKIP_INSTALL"] = "YES"
  s["ENABLE_USER_SCRIPT_SANDBOXING"] = "YES"
  s["CURRENT_PROJECT_VERSION"] = "1"
  s["MARKETING_VERSION"] = "1.0.0"
  s["DEVELOPMENT_TEAM"] = DEV_TEAM
  s["LD_RUNPATH_SEARCH_PATHS"] = "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks"
end

# Embed the widget extension in the app (PlugIns) + build-order dependency.
app.add_dependency(widget)
embed_phase = app.new_copy_files_build_phase("Embed Foundation Extensions")
embed_phase.symbol_dst_subfolder_spec = :plug_ins
embed_build_file = embed_phase.add_file_reference(widget.product_reference, true)
embed_build_file.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }

# ── Notification Service Extension (Reach rich-push body) ────────────────────
# Rewrites the visible Reach push body to the real reply text on the lock
# screen (the text never enters the APNs payload — privacy). Self-contained:
# Its constants come from the shared HaloReachKit wire type. Embedded in the app like the widget.
# See docs/specs/reach-notification-service-extension.md.
nse = project.new_target(:app_extension, "ReachNotificationService", :ios, DEPLOYMENT_TARGET)
nse_group = project.main_group.new_group(
  "ReachNotificationService", File.join(ROOT, "ReachNotificationService"))
nse_src = nse_group.new_file(
  File.join(ROOT, "ReachNotificationService", "NotificationService.swift"))
nse.add_file_references([nse_src])
nse_group.new_file(File.join(ROOT, "ReachNotificationService", "Info.plist"))
nse_group.new_file(File.join(ROOT, "ReachNotificationService", "ReachNotificationService.entitlements"))

nse.build_configurations.each do |config|
  s = config.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"] = NSE_BUNDLE_ID
  s["PRODUCT_NAME"] = "ReachNotificationService"
  s["IPHONEOS_DEPLOYMENT_TARGET"] = DEPLOYMENT_TARGET
  s["SWIFT_VERSION"] = "6.0"
  s["SWIFT_STRICT_CONCURRENCY"] = "complete"
  s["TARGETED_DEVICE_FAMILY"] = "1"
  s["INFOPLIST_FILE"] = "ReachNotificationService/Info.plist"
  s["INFOPLIST_KEY_CFBundleDisplayName"] = "ReachNotificationService"
  s["CODE_SIGN_ENTITLEMENTS"] = "ReachNotificationService/ReachNotificationService.entitlements"
  # Match the app's push environment per configuration (see the app target).
  s["APS_ENVIRONMENT"] = config.name == "Release" ? "production" : "development"
  s["GENERATE_INFOPLIST_FILE"] = "NO"
  s["SKIP_INSTALL"] = "YES"
  s["ENABLE_USER_SCRIPT_SANDBOXING"] = "YES"
  s["CURRENT_PROJECT_VERSION"] = "1"
  s["MARKETING_VERSION"] = "1.0.0"
  s["DEVELOPMENT_TEAM"] = DEV_TEAM
  s["LD_RUNPATH_SEARCH_PATHS"] = "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks"
end

# Embed in the app (same PlugIns phase as the widget) + build-order dependency.
app.add_dependency(nse)
nse_embed_file = embed_phase.add_file_reference(nse.product_reference, true)
nse_embed_file.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }

# ── Unit-test target (the wire-protocol round-trip) ─────────────────────────
tests = project.new_target(:unit_test_bundle, "HaloiOSTests", :ios, DEPLOYMENT_TARGET)
tests_group = project.main_group.new_group("Tests", File.join(ROOT, "Tests"))
Dir.children(File.join(ROOT, "Tests")).sort.each do |name|
  next unless name.end_with?(".swift")

  ref = tests_group.new_file(File.join(ROOT, "Tests", name))
  tests.add_file_references([ref])
end
tests.add_dependency(app)
tests.build_configurations.each do |config|
  s = config.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"] = "#{BUNDLE_ID}.tests"
  s["IPHONEOS_DEPLOYMENT_TARGET"] = DEPLOYMENT_TARGET
  s["SWIFT_VERSION"] = "6.0"
  s["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/HaloiOS.app/HaloiOS"
  s["BUNDLE_LOADER"] = "$(TEST_HOST)"
  s["GENERATE_INFOPLIST_FILE"] = "YES"
end

# ── Shared wire-type package (HaloReachKit) ──────────────────────────────────
# The ReachMessage wire type lives in its own public package so the app, the
# widget (ReachConfirmIntent writes CloudKit directly, outside the app process),
# the NSE (enriches lock-screen notifications with the real reply body), and the
# test target all compile the exact same type and can't drift. The Halo macOS
# app links the same package, so the phone and the Mac speak an identical wire.
reachkit = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
reachkit.repositoryURL = "https://github.com/HeyHalo-App/heyhalo-reach-kit.git"
reachkit.requirement = { "kind" => "upToNextMajorVersion", "minimumVersion" => "1.0.0" }
project.root_object.package_references << reachkit

def link_package_product(project, package_ref, target, product_name)
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = package_ref
  dep.product_name = product_name
  target.package_product_dependencies << dep
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  target.frameworks_build_phase.files << build_file
end

[app, widget, tests, nse].each do |t|
  link_package_product(project, reachkit, t, "HaloReachKit")
end

project.save

# ── Shared scheme (so xcodebuild -scheme HaloiOS works) ──────────────────────
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)

# Point the LaunchAction at the local StoreKit config so in-simulator runs can
# exercise the IAP flow (Subscribe / Restore / Manage) without a sandbox Apple
# Account. The App Store product of the same id (com.silvercommerce.halo.cloud.
# monthly) drives real builds; this file only matters for local testing. The
# identifier is the path relative to the .xcodeproj container.
storekit_ref = REXML::Element.new("StoreKitConfigurationFileReference")
storekit_ref.add_attribute("identifier", "../Halo.storekit")
scheme.launch_action.xml_element.add_element(storekit_ref)

scheme.save_as(PROJECT_PATH, "HaloiOS", true) # shared

puts "Generated #{PROJECT_PATH}"
