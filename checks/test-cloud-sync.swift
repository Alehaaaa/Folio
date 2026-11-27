// Folio Sync merge rules, run by checks/test-cloud-sync.sh.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok { failures += 1 }
}

func rec(_ keys: [String], progress: Double, status: String = "reading", opened: Date? = nil, updated: Date = .distantPast, collections: [String] = []) -> CloudSyncRecord {
    CloudSyncRecord(keys: keys, title: "T", author: "A", progress: progress, chapter: Int(progress * 10), fraction: 0.5, pdfPage: 0,
                    status: status, finishedAt: nil, lastOpenedAt: opened, collections: collections, updatedAt: updated)
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let mac = UUID(), phone = UUID()

// First sight: a book is as old as its last opening.
var state = CloudSyncState()
var local = CloudSyncMerge.stamp([(mac, rec(["hc:1", "t:a"], progress: 0.3, opened: t0))], state: &state, now: t0.addingTimeInterval(500))
check(local[mac]?.updatedAt == t0, "unseen book is stamped with its last-opened time")

// No change: the stamp stays.
local = CloudSyncMerge.stamp([(mac, rec(["hc:1", "t:a"], progress: 0.3, opened: t0))], state: &state, now: t0.addingTimeInterval(900))
check(local[mac]?.updatedAt == t0, "unchanged book keeps its stamp")

// A change is stamped when noticed.
let later = t0.addingTimeInterval(1000)
local = CloudSyncMerge.stamp([(mac, rec(["hc:1", "t:a"], progress: 0.4, opened: t0))], state: &state, now: later)
check(local[mac]?.updatedAt == later, "changed book is stamped now")

// A newer entry from another device applies; an older one doesn't.
let newer = CloudSyncDeviceDoc(deviceName: "iPhone", platform: "iphone", savedAt: later,
    books: [rec(["t:a"], progress: 0.7, opened: later.addingTimeInterval(50), updated: later.addingTimeInterval(60))])
var incoming = CloudSyncMerge.incoming(local: local, peers: [newer])
check(incoming[mac]?.record?.progress == 0.7, "newer progress from another device applies (matched by title key)")

let older = CloudSyncDeviceDoc(deviceName: "iPhone", platform: "iphone", savedAt: later,
    books: [rec(["hc:1"], progress: 0.1, updated: t0)])
incoming = CloudSyncMerge.incoming(local: local, peers: [older])
check(incoming[mac] == nil, "older progress from another device is ignored")

// A book open in the reader isn't moved.
incoming = CloudSyncMerge.incoming(local: local, peers: [newer], skipping: [mac])
check(incoming[mac] == nil, "open book is skipped")

// Same values, newer time: nothing to apply.
let same = CloudSyncDeviceDoc(deviceName: "iPhone", platform: "iphone", savedAt: later,
    books: [rec(["hc:1"], progress: 0.4, opened: t0, updated: later.addingTimeInterval(99))])
incoming = CloudSyncMerge.incoming(local: local, peers: [same])
check(incoming[mac] == nil, "identical state is not re-applied")

// Newest among several devices wins.
let ipad = CloudSyncDeviceDoc(deviceName: "iPad", platform: "ipad", savedAt: later,
    books: [rec(["hc:1"], progress: 0.9, updated: later.addingTimeInterval(120))])
incoming = CloudSyncMerge.incoming(local: local, peers: [newer, ipad])
check(incoming[mac]?.record?.progress == 0.9, "newest of several devices wins")

// Only last-opened differs: it moves forward without touching progress.
let opened = CloudSyncDeviceDoc(deviceName: "iPhone", platform: "iphone", savedAt: later,
    books: [rec(["hc:1"], progress: 0.1, opened: later.addingTimeInterval(300), updated: t0)])
incoming = CloudSyncMerge.incoming(local: local, peers: [opened])
check(incoming[mac]?.record == nil && incoming[mac]?.lastOpenedAt == later.addingTimeInterval(300), "later last-opened time comes over alone")

// Round trip through JSON keeps fingerprints equal.
let r = rec(["hc:1"], progress: 0.123456789, opened: t0, updated: t0, collections: ["B", "A"])
let back = try! JSONDecoder.folioSync.decode(CloudSyncRecord.self, from: JSONEncoder.folioSync.encode(r))
check(back.fingerprint == r.fingerprint, "fingerprint survives JSON")

// Removed books are forgotten.
_ = CloudSyncMerge.stamp([(phone, rec(["t:b"], progress: 0.2))], state: &state, now: later)
check(state.stamps[mac] == nil && state.stamps[phone] != nil, "removed books leave the state")

// Codes.
let code = CloudSyncMerge.newCode()
check(code.count == 16 && CloudSyncMerge.normalizedCode(CloudSyncMerge.display(code).lowercased()) == code, "codes survive display and lower case")
check(CloudSyncMerge.normalizedCode("abc") == nil, "short codes are refused")

// Sealing for the public store.
var channel = CloudSyncChannel()
channel.devices["dev-1"] = CloudSyncDeviceDoc(deviceName: "Mac", platform: "mac", savedAt: later, books: [r])
let sealed = try! CloudSyncBox.seal(channel, code: code)
check(sealed.hasPrefix(CloudSyncBox.prefix) && !sealed.contains("Mac"), "sealed document hides its contents")
check((try? CloudSyncBox.open(sealed, code: code))?.devices["dev-1"] == channel.devices["dev-1"], "sealed document opens with its code")
check((try? CloudSyncBox.open(sealed, code: CloudSyncMerge.newCode())) == nil, "another code can't open it")
check((try? CloudSyncBox.open("", code: code))?.devices.isEmpty == true, "an empty slot is an empty channel")
check(CloudSyncBox.slot(for: code) == CloudSyncBox.slot(for: code) && CloudSyncBox.slot(for: code) != CloudSyncBox.slot(for: CloudSyncMerge.newCode()), "each code has its own slot")
check(!CloudSyncBox.slot(for: code).contains(code), "the slot doesn't reveal the code")

// Synced settings: a new, empty device takes another device's copy; a change wins later.
var phoneState = CloudSyncState()
var phoneValues = CloudSyncMerge.stampValues(["ratings": "{}"], state: &phoneState, now: later)
var macState = CloudSyncState()
let macValues = CloudSyncMerge.stampValues(["ratings": "{\"hc-1\":4.5}"], state: &macState, now: later)
let macDoc = CloudSyncDeviceDoc(deviceName: "Mac", platform: "mac", savedAt: later, books: [], values: macValues)
check(CloudSyncMerge.incomingValues(local: phoneValues, peers: [macDoc])["ratings"]?.json == "{\"hc-1\":4.5}", "an empty device takes another device's settings")
check(CloudSyncMerge.incomingValues(local: macValues, peers: [CloudSyncDeviceDoc(deviceName: "iPhone", platform: "iphone", savedAt: later, books: [], values: phoneValues)]).isEmpty, "an empty copy never replaces a full one")
phoneValues = CloudSyncMerge.stampValues(["ratings": "{\"hc-2\":3}"], state: &phoneState, now: later.addingTimeInterval(60))
check(CloudSyncMerge.incomingValues(local: macValues, peers: [CloudSyncDeviceDoc(deviceName: "iPhone", platform: "iphone", savedAt: later, books: [], values: phoneValues)])["ratings"]?.json == "{\"hc-2\":3}", "a later change on another device wins")
let unchanged = CloudSyncMerge.stampValues(["ratings": "{\"hc-2\":3}"], state: &phoneState, now: later.addingTimeInterval(600))
check(unchanged["ratings"]?.updatedAt == phoneValues["ratings"]?.updatedAt, "an unchanged setting keeps its stamp")
check((try? JSONDecoder.folioSync.decode(CloudSyncDeviceDoc.self, from: Data(#"{"deviceName":"Old","platform":"mac","savedAt":0,"books":[]}"#.utf8)))?.values == nil, "documents from older versions still open")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("All merge checks passed")
