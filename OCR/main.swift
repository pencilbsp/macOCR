//
//  main.swift
//  OCR
//
//  Created by xulihang on 2023/1/1.
//

import Cocoa
import Vision

var MODE = VNRequestTextRecognitionLevel.accurate  // or .fast
var USE_LANG_CORRECTION = false
var REVISION: Int
if #available(macOS 11, *) {
    REVISION = VNRecognizeTextRequestRevision2
} else {
    REVISION = VNRecognizeTextRequestRevision1
}

let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png"]

/// 📖 Hàm kiểm tra xem đường dẫn là thư mục hay tệp
func isDirectory(at path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        && isDir.boolValue
}

func matchesPattern(_ filename: String) -> (start: String, end: String)? {
    let pattern =
        #"^(\d{1,}_\d{1,}_\d{1,}_\d{1,})__(\d{1,}_\d{1,}_\d{1,}_\d{1,})"#  // Lấy đúng 2 mốc thời gian
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }

    let range = NSRange(location: 0, length: filename.utf16.count)
    guard let match = regex.firstMatch(in: filename, options: [], range: range)
    else { return nil }

    let start = (filename as NSString).substring(with: match.range(at: 1))
    let end = (filename as NSString).substring(with: match.range(at: 2))
    return (start, end)
}

func formatTimestamp(_ timestamp: String) -> String {
    // Chuyển đổi: "0_00_12_468" → "00:00:12,468"
    let components = timestamp.split(separator: "_")
    guard components.count == 4 else { return "00:00:00,000" }

    let hours = Int(components[0]) ?? 0
    let minutes = Int(components[1]) ?? 0
    let seconds = Int(components[2]) ?? 0
    let milliseconds = Int(components[3]) ?? 0

    return String(
        format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
}

func parseTimestamp(_ timestamp: String) -> TimeInterval? {
    let components = timestamp.split(separator: "_").compactMap { Int($0) }
    guard components.count == 4 else { return nil }

    let hours = components[0]
    let minutes = components[1]
    let seconds = components[2]
    let milliseconds = components[3]

    return TimeInterval(hours * 3600 + minutes * 60 + seconds) + Double(
        milliseconds) / 1000.0
}

/// 🖼️ Hàm đọc tất cả các tệp ảnh từ thư mục
func imageFiles(in directoryPath: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directoryPath))?
        .filter { file in
            let filename = URL(fileURLWithPath: file).deletingPathExtension()
                .lastPathComponent
            return supportedImageExtensions.contains(
                URL(fileURLWithPath: file).pathExtension.lowercased())
                && matchesPattern(filename) != nil
        }
        .map { directoryPath + "/" + $0 } ?? []
}

/// 📝 Hàm xử lý OCR cho 1 ảnh
func recognizeText(
    from imagePath: String, languages: [String],
    completion: @escaping ([String: Any]?) -> Void
) {
    guard let img = NSImage(byReferencingFile: imagePath),
        let imgRef = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
        fputs(
            "❌ Error: failed to load or convert image '\(imagePath)'\n", stderr)
        completion(nil)
        return
    }

    let request = VNRecognizeTextRequest { (request, error) in
        guard error == nil else {
            fputs(
                "❌ Error recognizing text in '\(imagePath)': \(error!.localizedDescription)\n",
                stderr)
            completion(nil)
            return
        }

        let observations =
            request.results as? [VNRecognizedTextObservation] ?? []
        var lines: [[String: Any]] = []
        var allText = ""

        for (index, observation) in observations.enumerated() {
            guard let candidate = observation.topCandidates(1).first else {
                continue
            }
            let string = candidate.string
            let confidence = candidate.confidence

            let stringRange = string.startIndex..<string.endIndex
            let boxObservation = try? candidate.boundingBox(for: stringRange)
            let boundingBox = boxObservation?.boundingBox ?? .zero
            let rect = VNImageRectForNormalizedRect(
                boundingBox, Int(imgRef.width), Int(imgRef.height))

            lines.append([
                "text": string,
                "confidence": confidence,
                "x": Int(rect.minX),
                "width": Int(rect.width),
                "y": Int(CGFloat(imgRef.height) - rect.minY - rect.height),
                "height": Int(rect.height),
            ])

            allText += string + (index < observations.count - 1 ? "\n" : "")
        }

        completion([
            "lines": lines,
            "text": allText,
            "image": URL(fileURLWithPath: imagePath).lastPathComponent,
        ])
    }

    request.recognitionLevel = MODE
    request.usesLanguageCorrection = USE_LANG_CORRECTION
    request.revision = REVISION
    request.recognitionLanguages = languages

    try? VNImageRequestHandler(cgImage: imgRef, options: [:]).perform([request])
}

func recognizeImages(from images: [String], languages: [String]) -> [[String:
    Any]]
{
    var results = [[String: Any]?](repeating: nil, count: images.count)
    let group = DispatchGroup()

    for (index, imagePath) in images.enumerated() {
        guard
            let (start, end) = matchesPattern(
                URL(fileURLWithPath: imagePath).deletingPathExtension()
                    .lastPathComponent)
        else {
            print("⚠️ Skipped: Invalid filename format - \(imagePath)")
            continue
        }

        group.enter()
        recognizeText(from: imagePath, languages: languages) { result in
            defer { group.leave() }

            guard let text = result?["text"] as? String else {
                print("❌ OCR failed for \(imagePath)")
                return
            }

            results[index] = [
                "start": start,
                "end": end,
                "text": text,
            ]
        }
    }

    group.wait()
    return results.compactMap { $0 }.sorted { file1, file2 in
        guard
            let time1 = parseTimestamp(file1["start"] as? String ?? ""),
            let time2 = parseTimestamp(file2["start"] as? String ?? "")
        else {
            return false  // Nếu không thể so sánh, giữ nguyên thứ tự
        }
        return time1 < time2  // ✅ Sắp xếp tăng dần theo thời gian bắt đầu
    }
}

func generateSubtitle(from imagesText: [[String: Any]], isSubtitle: Bool)
    -> String
{
    var content = ""

    for (index, item) in imagesText.enumerated() {
        guard
            let start = item["start"] as? String,
            let end = item["end"] as? String,
            let allText = item["text"] as? String
        else {
            continue  // Bỏ qua nếu thiếu dữ liệu
        }

        let startTime = formatTimestamp(start)
        let endTime = formatTimestamp(end)

        content +=
            isSubtitle
            ? """
            \(index + 1)
            \(startTime) --> \(endTime)
            \(allText + "\n")
            
            """ : allText + "\n"
    }

    return content.trimmingCharacters(in: .whitespacesAndNewlines)
}

func main(args: [String]) -> Int32 {

    if CommandLine.arguments.count == 2 {
        if args[1] == "--langs" {
            let request = VNRecognizeTextRequest.init()
            request.revision = REVISION
            request.recognitionLevel = VNRequestTextRecognitionLevel.accurate
            let langs = try? request.supportedRecognitionLanguages()
            for lang in langs! {
                print(lang)
            }
        }
        return 0
    } else if CommandLine.arguments.count >= 5 {
        let (language, fastmode, languageCorrection, src) = (
            args[1], args[2], args[3], args[4]
        )
        let dst = (CommandLine.arguments.count == 6) ? args[5] : nil

        let substrings = language.split(separator: ",")
        var languages: [String] = []
        for substring in substrings {
            languages.append(String(substring))
        }
        if fastmode == "true" {
            MODE = VNRequestTextRecognitionLevel.fast
        } else {
            MODE = VNRequestTextRecognitionLevel.accurate
        }

        if languageCorrection == "true" {
            USE_LANG_CORRECTION = true
        } else {
            USE_LANG_CORRECTION = false
        }

        if isDirectory(at: src) {
            // 📂 Nếu là thư mục -> xử lý tất cả ảnh
            let images = imageFiles(in: src)

            guard !images.isEmpty else {
                fputs("❌ No supported images found in '\(src)'\n", stderr)
                return 1
            }

            let imagesText = recognizeImages(from: images, languages: languages)

            if let dst = dst {
                let content = generateSubtitle(
                    from: imagesText, isSubtitle: dst.hasSuffix(".srt"))

                do {
                    try content.write(
                        to: URL(fileURLWithPath: dst), atomically: true,
                        encoding: .utf8)
                    print("✅ Created: \(dst)")
                } catch {
                    fputs(
                        "❌ Failed to write: \(error.localizedDescription)\n",
                        stderr)
                }
            } else {
                print(imagesText)
            }

        } else {
            // 🖼️ Nếu là tệp -> xử lý ảnh đơn
            let group = DispatchGroup()
            group.enter()
            recognizeText(from: src, languages: languages) { result in
                if let result = result {
                    if let dst = dst {
                        do {
                            let data = try JSONSerialization.data(
                                withJSONObject: result, options: .prettyPrinted)
                            try data.write(to: URL(fileURLWithPath: dst))
                        } catch {
                            fputs("❌ Failed to write to '\(dst)'\n", stderr)
                        }
                    } else {
                        print("🖼️ Image: \(result["image"] ?? "")")
                        print("📝 Text:\n\(result["text"] ?? "")")
                    }
                }
                group.leave()
            }
            group.wait()
        }

        return 0
    } else {
        print(
            """
            usage:
              macOCR language fastmode languageCorrection image_or_directory_path [output_path]
              --langs: list supported languages

            examples:
              macOCR en false true ./image.jpg out.json       # OCR cho 1 ảnh -> ghi ra file
              macOCR en false true ./image.jpg                # OCR cho 1 ảnh -> in ra console
              macOCR en false true ./images_folder out.json  # OCR cho tất cả ảnh trong thư mục -> ghi ra file
              macOCR en false true ./images_folder           # OCR cho tất cả ảnh -> in ra console
            """)
        return 1
    }
}

exit(main(args: CommandLine.arguments))
