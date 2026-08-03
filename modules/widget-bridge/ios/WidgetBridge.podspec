Pod::Spec.new do |s|
  s.name           = 'WidgetBridge'
  s.version        = '1.0.0'
  s.summary        = 'App Group bridge for TradeReady home-screen widgets'
  s.description    = 'Mirrors a minimal snapshot of app data into the shared App Group container so WidgetKit extensions and Siri App Intents can read it.'
  s.author         = 'TradeReady'
  s.homepage       = 'https://gettradereadyapp.com'
  s.platforms      = { :ios => '15.1' }
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }

  s.source_files = '**/*.{h,m,mm,swift}'
end
