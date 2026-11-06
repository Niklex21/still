import Foundation
import Vision
import ImageIO
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let req = VNRecognizeTextRequest()
req.recognitionLevel = CommandLine.arguments.contains("--fast") ? .fast : .accurate
req.usesLanguageCorrection = true
let start = Date()
try VNImageRequestHandler(url: url).perform([req])
print("OCR completed in", Date().timeIntervalSince(start), "seconds")
for text in req.results ?? [] { print(text.topCandidates(1).first?.string ?? "EMPTY") }
