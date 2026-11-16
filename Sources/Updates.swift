// Snapmark — https://github.com/lucas-azambuja/snapmark — MIT License
import Cocoa

// MARK: - Update check against the GitHub releases

/// A version like "0.1.0", "0.1.0-alpha.3" or "v1.2.0-beta.1", comparable the semver way:
/// a pre-release comes before its final version, and its number breaks ties.
struct Version: Comparable, CustomStringConvertible {
    let numbers: [Int]
    let pre: (tag: String, number: Int)?
    let description: String

    init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") { s.removeFirst() }
        description = s
        let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
        let nums = parts[0].split(separator: ".").compactMap { Int($0) }
        guard !nums.isEmpty else { return nil }
        numbers = nums + Array(repeating: 0, count: max(0, 3 - nums.count))
        if parts.count > 1 {
            let p = parts[1].split(separator: ".").map(String.init)
            pre = (p[0], p.count > 1 ? Int(p[1]) ?? 0 : 0)
        } else {
            pre = nil
        }
    }

    static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }

    static func < (a: Version, b: Version) -> Bool {
        for (x, y) in zip(a.numbers, b.numbers) where x != y { return x < y }
        switch (a.pre, b.pre) {
        case (nil, nil): return false
        case (nil, _): return false          // final > pre-release
        case (_, nil): return true
        case let (x?, y?): return x.tag != y.tag ? x.tag < y.tag : x.number < y.number
        }
    }
}

struct AvailableUpdate {
    let version: Version
    let page: URL
}

final class UpdateChecker {
    static let shared = UpdateChecker()
    static let releasesAPI = URL(string: "https://api.github.com/repos/lucas-azambuja/snapmark/releases?per_page=10")!
    static let releasesPage = URL(string: "https://github.com/lucas-azambuja/snapmark/releases")!

    private(set) var available: AvailableUpdate?
    /// Called on the main queue whenever `available` changes.
    var onChange: (() -> Void)?
    private var timer: Timer?

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "checkForUpdates")
            schedule()
        }
    }

    /// Checks shortly after launch and then once a day, if automatic checks are on.
    func schedule() {
        timer?.invalidate()
        timer = nil
        guard automatic else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check(completion: nil) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.check(completion: nil)
        }
    }

    /// Looks for a release newer than this build. `completion` gets the update (or nil) and an error, on the main queue.
    func check(completion: ((AvailableUpdate?, Error?) -> Void)?) {
        var req = URLRequest(url: Self.releasesAPI, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Snapmark", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            let update = data.flatMap { Self.newest(in: $0) }.flatMap { u -> AvailableUpdate? in
                guard let current = Version(AppInfo.version), u.version > current else { return nil }
                return u
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if error == nil {
                    self.available = update
                    self.onChange?()
                }
                completion?(update, error)
            }
        }.resume()
    }

    /// The newest published (non-draft) release in the API response.
    private static func newest(in data: Data) -> AvailableUpdate? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.compactMap { r -> AvailableUpdate? in
            guard (r["draft"] as? Bool) != true, let tag = r["tag_name"] as? String, let v = Version(tag) else { return nil }
            let page = (r["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
            return AvailableUpdate(version: v, page: page)
        }.max { $0.version < $1.version }
    }
}

extension NSImage {
    /// The menu bar icon with a small dot in the corner (still a template, so it follows light/dark).
    func withBadge() -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            let d = rect.width * 0.36
            let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
