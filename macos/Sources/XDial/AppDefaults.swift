import Foundation

/// Formal builds retain the established data domain. Development builds use a
/// separate domain for app preferences. Profiles use ConfigurationStorage instead.
let xdialDefaults =
    UserDefaults(suiteName: XDialBuildIdentity.dataIdentifier)
        ?? UserDefaults.standard
