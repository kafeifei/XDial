import Foundation

/// Executable identities may change during signed migrations, but the user
/// profile remains in this stable data domain and must never be discarded.
let xdialDefaults =
    UserDefaults(suiteName: "com.kafeifei.xdial") ?? UserDefaults.standard
