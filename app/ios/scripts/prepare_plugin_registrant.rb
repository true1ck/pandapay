#!/usr/bin/env ruby

# Flutter generates this file and includes iOS dev-dependency plugins even in
# release builds. Keep integration_test available in Debug, but make sure the
# release compiler neither imports nor registers its plugin.
registrant = File.join(__dir__, '..', 'Runner', 'GeneratedPluginRegistrant.m')
source = File.read(registrant)

import_pattern = /^#if __has_include\(<integration_test\/IntegrationTestPlugin\.h>\)\n#import <integration_test\/IntegrationTestPlugin\.h>\n#else\n@import integration_test;\n#endif$/
registration_pattern = /^  \[IntegrationTestPlugin registerWithRegistrar:\[registry registrarForPlugin:@"IntegrationTestPlugin"\]\];$/
guarded_import = "#if DEBUG\n#if __has_include(<integration_test/IntegrationTestPlugin.h>)"
guarded_registration = "#if DEBUG\n  [IntegrationTestPlugin registerWithRegistrar:"

if source.include?(guarded_import)
  # Already guarded by an earlier build.
elsif source.match?(import_pattern)
  updated = source.sub(import_pattern) { |block| "#if DEBUG\n#{block}\n#endif" }
  abort 'Could not locate the generated integration_test import to guard.' if updated == source
  source = updated
elsif source.include?('IntegrationTestPlugin')
  abort 'The generated integration_test import has an unexpected format.'
else
  # No iOS integration-test plugin is registered in this app configuration.
  exit 0
end

if source.include?(guarded_registration)
  # Already guarded by an earlier build.
elsif source.match?(registration_pattern)
  updated = source.sub(registration_pattern) { |line| "#if DEBUG\n#{line}\n#endif" }
  abort 'Could not locate the generated integration_test registration to guard.' if updated == source
  source = updated
else
  abort 'Could not locate the generated integration_test registration to guard.'
end

File.write(registrant, source)
