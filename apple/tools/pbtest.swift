import AppKit
// Test helper for the private pasteboard used by NC_PASTEBOARD.
//   pbtest <name> write-text <text> | write-image <png> | read | types
let args = CommandLine.arguments
let pb = NSPasteboard(name: NSPasteboard.Name(args[1]))
switch args[2] {
case "write-text":
  pb.clearContents(); pb.setString(args[3], forType: .string); print("changeCount", pb.changeCount)
case "write-concealed":
  pb.clearContents(); let item = NSPasteboardItem(); item.setString(args[3], forType: .string)
  item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")); pb.writeObjects([item]); print("changeCount", pb.changeCount)
case "write-image":
  pb.clearContents(); pb.setData(try! Data(contentsOf: URL(fileURLWithPath: args[3])), forType: .png); print("changeCount", pb.changeCount)
case "read":
  print("types:", (pb.types ?? []).map(\.rawValue).joined(separator: ","))
  print("text:", pb.string(forType: .string) ?? "<none>")
  if let png = pb.data(forType: .png) { print("png bytes:", png.count) }
default: print("?")
}

