import Foundation
// Writes the .DS_Store that gives the mounted, writable DMG volume its installer layout
// (icon view, hidden toolbar/sidebar, 128 pt icons, background picture, icon positions),
// without scripting Finder, so it works headless (CI) as well.
// Format: Buddy-allocator file with a single-leaf B-tree of records (as documented by
// Mark Mentovai and implemented by the ds_store / mac_alias Python packages).
//
// Usage: swift scripts/make-dmg-dsstore.swift <volume mount point> <app name>

let args = CommandLine.arguments
guard args.count == 3 else { FileHandle.standardError.write(Data("usage: make-dmg-dsstore <mount> <AppName.app>\n".utf8)); exit(64) }
let mount = URL(fileURLWithPath: args[1])
let appName = args[2]
let background = mount.appendingPathComponent(".background/background.tiff")

// Window: 640×400 content area (matches the background), icons centered at y=190.
let windowW = 640, windowH = 400, titleBar = 28
let iconPositions = [appName: (160, 190), "Applications": (480, 190)]

// MARK: - Binary helpers

extension Data {
    mutating func u8(_ v: UInt8) { append(v) }
    mutating func u16(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)]) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) { for s in [24, 16, 8, 0] { append(UInt8((v >> UInt32(s)) & 0xff)) } }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xffff_ffff)) }
    mutating func fourCC(_ s: String) { append(contentsOf: Array(s.utf8)) }
    mutating func pascal(_ s: String, field: Int) { // fixed-size Pascal string field
        let bytes = Array(s.utf8.prefix(field - 1))
        u8(UInt8(bytes.count)); append(contentsOf: bytes); append(contentsOf: [UInt8](repeating: 0, count: field - 1 - bytes.count))
    }
    mutating func tag(_ tag: Int16, _ payload: Data) {
        i16(tag); u16(UInt16(payload.count)); append(payload)
        if payload.count & 1 == 1 { u8(0) }
    }
}

// MARK: - Alias record (version 2) pointing at the background picture

func macSeconds(_ date: Date) -> Double { date.timeIntervalSince1970 + 2_082_844_800 } // since 1904-01-01

func inode(_ url: URL) -> UInt32 {
    var st = stat()
    guard stat(url.path, &st) == 0 else { fatalError("stat failed: \(url.path)") }
    return UInt32(truncatingIfNeeded: st.st_ino) // the HFS+ catalog node ID
}

func backgroundAlias() throws -> Data {
    let vol = try mount.resourceValues(forKeys: [.volumeNameKey, .volumeCreationDateKey])
    let volName = vol.volumeName ?? mount.lastPathComponent
    let volDate = macSeconds(vol.volumeCreationDate ?? Date())
    let fileDate = macSeconds(try background.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date())
    let folder = background.deletingLastPathComponent()
    let folderCNID = inode(folder), fileCNID = inode(background)
    let fileName = background.lastPathComponent, folderName = folder.lastPathComponent

    var d = Data()
    d.u32(0)                        // application info
    d.u16(0)                        // record size, patched below
    d.u16(2)                        // version
    d.u16(0)                        // kind: file
    d.pascal(volName, field: 28)
    d.u32(UInt32(volDate))
    d.fourCC("H+")                  // file system type
    d.u16(0)                        // disk type: fixed
    d.u32(folderCNID)
    d.pascal(fileName, field: 64)
    d.u32(fileCNID)
    d.u32(UInt32(fileDate))
    d.u32(0); d.u32(0)              // creator, type
    d.i16(-1); d.i16(-1)            // levels from / to
    d.u32(0)                        // volume attributes
    d.u16(0)                        // file system id
    d.append(Data(count: 10))

    func utf16(_ s: String) -> Data {
        var p = Data(); p.u16(UInt16(s.utf16.count)); for c in s.utf16 { p.u16(c) }; return p
    }
    var hi = Data(); hi.u64(UInt64(volDate * 65536))
    var hiFile = Data(); hiFile.u64(UInt64(fileDate * 65536))
    var cnidPath = Data(); cnidPath.u32(folderCNID)
    d.tag(0, Data(folderName.utf8))                                   // folder name
    d.tag(16, hi)                                                     // volume creation date (hi-res)
    d.tag(17, hiFile)                                                 // file creation date (hi-res)
    d.tag(1, cnidPath)                                                // CNID path
    d.tag(2, Data("\(volName):\(folderName):\(fileName)".utf8))      // Carbon path
    d.tag(14, utf16(fileName))                                        // Unicode file name
    d.tag(15, utf16(volName))                                         // Unicode volume name
    d.tag(18, Data("/\(folderName)/\(fileName)".utf8))               // POSIX path on the volume
    d.tag(19, Data("/Volumes/\(volName)".utf8))                      // POSIX path of the mount point
    d.i16(-1); d.u16(0)                                               // end
    let size = UInt16(d.count)
    d[4] = UInt8(size >> 8); d[5] = UInt8(size & 0xff)
    return d
}

// MARK: - Records

func plist(_ dict: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
}

struct Record { let name: String; let code: String; let type: String; let payload: Data }
var records: [Record] = []
func blob(_ name: String, _ code: String, _ data: Data) {
    var p = Data(); p.u32(UInt32(data.count)); p.append(data)
    records.append(Record(name: name, code: code, type: "blob", payload: p))
}

blob(".", "bwsp", try plist([
    "ContainerShowSidebar": false, "ShowSidebar": false, "ShowStatusBar": false,
    "ShowTabView": false, "ShowToolbar": false, "ShowPathbar": false, "PreviewPaneVisibility": false,
    "WindowBounds": "{{200, 120}, {\(windowW), \(windowH + titleBar)}}",
]))
blob(".", "icvp", try plist([
    "viewOptionsVersion": 1, "backgroundType": 2, "backgroundImageAlias": try backgroundAlias(),
    "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
    "arrangeBy": "none", "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
    "iconSize": 128.0, "textSize": 13.0, "labelOnBottom": true,
    "showIconPreview": true, "showItemInfo": false, "scrollPositionX": 0.0, "scrollPositionY": 0.0,
]))
var vSrn = Data(); vSrn.u32(1)
records.append(Record(name: ".", code: "vSrn", type: "long", payload: vSrn))
for (name, (x, y)) in iconPositions {
    var loc = Data(); loc.u32(UInt32(x)); loc.u32(UInt32(y)); loc.append(contentsOf: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0])
    blob(name, "Iloc", loc)
}
records.sort { a, b in
    let (x, y) = (a.name.lowercased(), b.name.lowercased())
    return x != y ? x.utf16.lexicographicallyPrecedes(y.utf16) : a.code.utf8.lexicographicallyPrecedes(b.code.utf8)
}

// MARK: - B-tree leaf + buddy allocator

var leaf = Data()
leaf.u32(0)                         // no child: this node is a leaf
leaf.u32(UInt32(records.count))
for r in records {
    leaf.u32(UInt32(r.name.utf16.count)); for c in r.name.utf16 { leaf.u16(c) }
    leaf.fourCC(r.code); leaf.fourCC(r.type); leaf.append(r.payload)
}
precondition(leaf.count <= 4096, "records do not fit in one B-tree page")

// Blocks (offsets are relative to file byte 4): header 0+32, DSDB 32+32, root 2048+2048, leaf 4096+4096.
let dsdbOff: UInt32 = 32, rootOff: UInt32 = 2048, rootSize: UInt32 = 2048, leafOff: UInt32 = 4096
var dsdb = Data()
dsdb.u32(2)                         // root node = block 2
dsdb.u32(0)                         // internal levels
dsdb.u32(UInt32(records.count))
dsdb.u32(1)                         // nodes
dsdb.u32(4096)                      // page size

var root = Data()
let blocks: [UInt32] = [rootOff | 11, dsdbOff | 5, leafOff | 12] // offset | log2(size)
root.u32(UInt32(blocks.count)); root.u32(0)
for i in 0..<256 { root.u32(i < blocks.count ? blocks[i] : 0) }
root.u32(1); root.u8(4); root.fourCC("DSDB"); root.u32(1) // table of contents: DSDB → block 1
// Free lists for sizes 2^0 … 2^31, consistent with the buddy layout above.
let freeAt = Set(6...10).union(13...30)
for k in 0..<32 {
    if freeAt.contains(k) { root.u32(1); root.u32(UInt32(1) << UInt32(k)) } else { root.u32(0) }
}
precondition(root.count <= Int(rootSize))

var file = Data(count: 4 + 8192)
func put(_ d: Data, at off: UInt32) { file.replaceSubrange(Int(off) + 4 ..< Int(off) + 4 + d.count, with: d) }
var header = Data()
header.u32(1); header.fourCC("Bud1"); header.u32(rootOff); header.u32(rootSize); header.u32(rootOff)
header.append(Data(count: 16))
file.replaceSubrange(0..<header.count, with: header)
put(dsdb, at: dsdbOff)
put(root, at: rootOff)
put(leaf, at: leafOff)

try file.write(to: mount.appendingPathComponent(".DS_Store"))
print("Layout: wrote \(records.count) .DS_Store records")
