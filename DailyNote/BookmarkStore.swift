import Foundation

/// Persists the security-scoped bookmark to the vault folder the user picked.
/// On iOS, a bookmark made from a security-scoped URL is implicitly
/// security-scoped — `.withSecurityScope` is macOS-only and must not be used.
enum BookmarkStore {
    private static let key = "vaultBookmark"

    /// Call while the URL's security scope is active (right after the picker).
    static func save(_ url: URL) throws {
        let data = try url.bookmarkData()
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Resolves the stored bookmark, silently renewing it if stale.
    /// Returns nil if nothing is stored or the folder is gone — caller should
    /// prompt for a fresh pick. Does not start the security scope.
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale {
            let started = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData() {
                UserDefaults.standard.set(fresh, forKey: key)
            }
            if started { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
