// f2_pairing_payload.swift — F2 pairing QR payload builder (Mac side).
//
// Usage: swift scripts/f2_pairing_payload.swift <url> <username> <password>
// Prints the compact v1 JSON that the Hermes Fleet iOS app's pairing scanner
// decodes (same shape + escaping rules as FleetCore PairingPayload.encoded()).
//
// SECURITY: the output is credential material — never log or commit it.
import Foundation

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: swift f2_pairing_payload.swift <url> <username> <password>\n".data(using: .utf8)!)
    exit(64)
}

func quote(_ raw: String) -> String {
    var out = "\""
    for scalar in raw.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
            else { out.unicodeScalars.append(scalar) }
        }
    }
    return out + "\""
}

print("{\"password\":\(quote(args[3])),\"url\":\(quote(args[1])),\"username\":\(quote(args[2])),\"v\":1}", terminator: "")
