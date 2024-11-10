Pod::Spec.new do |s|
  s.name             = 'jitsi_meet_flutter_sdk'
  s.version          = '10.2.1'
  s.summary          = 'Jitsi Meet Flutter SDK'
  s.description      = <<-DESC
Jitsi Meet Flutter SDK
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  
  s.vendored_frameworks = 'Frameworks/JitsiMeetSDK.xcframework'
  
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