import Foundation

guard CommandLine.arguments.count == 6 else {
    fputs("usage: PackICNS <128.png> <256.png> <512.png> <1024.png> <output.icns>\n", stderr)
    exit(64)
}

let entries = [
    ("ic07", CommandLine.arguments[1]),
    ("ic08", CommandLine.arguments[2]),
    ("ic09", CommandLine.arguments[3]),
    ("ic10", CommandLine.arguments[4]),
]

func bigEndian(_ value: UInt32) -> Data {
    var encoded = value.bigEndian
    return Data(bytes: &encoded, count: MemoryLayout<UInt32>.size)
}

var body = Data()
for (type, path) in entries {
    let payload = try Data(contentsOf: URL(fileURLWithPath: path))
    body.append(type.data(using: .ascii)!)
    body.append(bigEndian(UInt32(payload.count + 8)))
    body.append(payload)
}

var output = Data("icns".utf8)
output.append(bigEndian(UInt32(body.count + 8)))
output.append(body)
try output.write(
    to: URL(fileURLWithPath: CommandLine.arguments[5]),
    options: .atomic
)
