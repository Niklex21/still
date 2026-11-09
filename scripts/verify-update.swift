import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 5 else { fatalError("Expected feed, asset URL, DMG, and Info.plist") }
let document = try XMLDocument(contentsOf: URL(fileURLWithPath: args[1]), options: [])
let attribute = "edSignature"
let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
let items = try document.nodes(forXPath: "/rss/channel/item/enclosure").compactMap { $0 as? XMLElement }
let bundleInfo = NSDictionary(contentsOfFile: args[4])
let archive = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
guard let entry = items.first(where: { $0.attribute(forName: "url")?.stringValue == args[2] }),
      entry.attribute(forName: "length")?.stringValue == String(archive.count),
      let encoded = entry.attribute(forLocalName: attribute, uri: namespace)?.stringValue,
      let signature = Data(base64Encoded: encoded),
      let key = bundleInfo?["SUPublicEDKey"] as? String, let raw = Data(base64Encoded: key),
      try Curve25519.Signing.PublicKey(rawRepresentation: raw).isValidSignature(signature, for: archive)
else { fputs("Missing or invalid Sparkle signature for the published update.\n", stderr); exit(1) }
print("Verified signed update:", args[2])
