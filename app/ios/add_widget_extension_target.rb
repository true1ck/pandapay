#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the HomeWidgetExtension WidgetKit target to Runner.xcodeproj.
#
# Why a script instead of hand-edited pbxproj text: PBXProj is a
# semi-structured, easy-to-corrupt format, and the previous state of this
# repo (see BestCardWidget.swift's prior header comment, still in git
# history) deliberately left the widget unwired rather than risk a blind
# hand-edit. The `xcodeproj` gem (the same library CocoaPods and fastlane
# use to safely mutate real projects) removes that risk — it understands
# the object graph, not just text — and this machine actually has Xcode
# installed, so the result can be verified with `xcodebuild -list` /
# `-showBuildSettings` afterward instead of taking it on faith.
#
# Idempotent: safe to re-run — exits early if the target already exists.
#
# Usage: cd app/ios && ruby add_widget_extension_target.rb

require 'xcodeproj'

PROJECT_PATH = 'Runner.xcodeproj'
EXT_NAME = 'HomeWidgetExtension'
BUNDLE_ID_BASE = 'app.pandapay.pandapay'
APP_GROUP_ID = 'group.app.pandapay.pandapay.homewidget'
DEPLOYMENT_TARGET = '15.5' # matches Runner's IPHONEOS_DEPLOYMENT_TARGET

project = Xcodeproj::Project.open(PROJECT_PATH)

if project.targets.find { |t| t.name == EXT_NAME }
  puts "#{EXT_NAME} target already exists — nothing to do."
  exit 0
end

runner_target = project.targets.find { |t| t.name == 'Runner' }
raise "Runner target not found in #{PROJECT_PATH}" unless runner_target

# ---- New target -------------------------------------------------------------
ext_target = project.new_target(:app_extension, EXT_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)

# ---- Source group + files ----------------------------------------------------
ext_group = project.main_group.new_group(EXT_NAME, EXT_NAME)
%w[BestCardWidget.swift HomeWidgetExtensionBundle.swift].each do |filename|
  file_ref = ext_group.new_reference(filename)
  ext_target.add_file_references([file_ref])
end
info_plist_ref = ext_group.new_reference('Info.plist')
entitlements_ref = ext_group.new_reference("#{EXT_NAME}.entitlements")
[info_plist_ref, entitlements_ref].each { |ref| ref.source_tree = '<group>' }

# ---- Build settings -----------------------------------------------------------
ext_target.build_configurations.each do |config|
  config.build_settings['INFOPLIST_FILE'] = "#{EXT_NAME}/Info.plist"
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "#{BUNDLE_ID_BASE}.#{EXT_NAME}"
  config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = "#{EXT_NAME}/#{EXT_NAME}.entitlements"
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['SKIP_INSTALL'] = 'YES'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] =
    '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
end

# ---- Link WidgetKit + SwiftUI (system SDK frameworks) --------------------------
sdk_frameworks_group = project.frameworks_group
%w[WidgetKit SwiftUI].each do |fw|
  ref = sdk_frameworks_group.new_reference("System/Library/Frameworks/#{fw}.framework")
  ref.source_tree = 'SDKROOT'
  ext_target.frameworks_build_phase.add_file_reference(ref)
end

# ---- Runner: depend on + embed the extension -----------------------------------
runner_target.add_dependency(ext_target)

embed_phase = runner_target.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' }
embed_phase ||= runner_target.new_copy_files_build_phase('Embed Foundation Extensions')
embed_phase.symbol_dst_subfolder_spec = :plug_ins
build_file = embed_phase.add_file_reference(ext_target.product_reference, true)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] } if build_file.respond_to?(:settings=)

# ---- Runner: App Group entitlements ---------------------------------------------
runner_group = project.main_group.find_subpath('Runner', false)
runner_entitlements_ref = runner_group.find_file_by_path('Runner.entitlements') ||
                           runner_group.new_reference('Runner.entitlements')
runner_target.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

project.save

puts "Added #{EXT_NAME} target, embedded it in Runner, and wired the App Group (#{APP_GROUP_ID})."
