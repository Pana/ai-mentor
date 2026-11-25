// 繁体转简体：从标准输入一行一行读，用系统自带的 ICU 转换（Hant-Hans）后写到标准输出，行数不变。
// scripts/poems/import.mjs 调用它，只能在 macOS 上跑。ICU 按字转换，个别字由 import.mjs 再修正。
import Foundation

let transform = StringTransform("Hant-Hans")
var out = FileHandle.standardOutput
var buffer = ""
while let line = readLine(strippingNewline: true) {
  buffer += (line.applyingTransform(transform, reverse: false) ?? line) + "\n"
  if buffer.utf8.count > 1 << 20 {
    out.write(buffer.data(using: .utf8)!)
    buffer = ""
  }
}
out.write(buffer.data(using: .utf8)!)
