import Foundation

/// Formal builds retain the established data domain. Development builds use a
/// separate domain and never import or mutate formal data.
let xdialDefaults =
    UserDefaults(suiteName: XDialBuildIdentity.dataIdentifier)
        ?? UserDefaults.standard
