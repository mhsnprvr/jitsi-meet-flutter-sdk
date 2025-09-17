Pod::Spec.new do |s|
  s.name             = 'jitsi_meet_flutter_sdk'
  s.version          = '11.5.1'
  s.summary          = 'Jitsi Meet Flutter SDK'
  s.description      = <<-DESC
Jitsi Meet Flutter SDK
                       DESC
  s.homepage         = 'https://jitsi.github.io/handbook/docs/dev-guide/dev-guide-flutter-sdk'
  s.authors          = 'Jitsi Meet'
  s.license          = { :file => '../LICENSE' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'JitsiMeetSDK', '11.5.1'
  s.platform = :ios, '15.1'
  s.pod_target_xcconfig = { 
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'ENABLE_BITCODE' => 'NO',
    'SWIFT_OPTIMIZATION_LEVEL' => '-O',
    'GCC_OPTIMIZATION_LEVEL' => 's',
    'STRIP_INSTALLED_PRODUCT' => 'YES',
    'DEPLOYMENT_POSTPROCESSING' => 'YES',
    'SEPARATE_STRIP' => 'YES',
    'OTHER_LDFLAGS' => '$(inherited) -Xlinker -no_objc_category_merging'
  }
  s.swift_version = '5.0'
end