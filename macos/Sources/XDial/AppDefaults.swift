import Foundation

/// Local Debug builds can use a separately provisioned host bundle identifier,
/// but they must share the canonical XDial profile with the release app.
let xdialDefaults =
    UserDefaults(suiteName: "com.kafeifei.xdial") ?? UserDefaults.standard
