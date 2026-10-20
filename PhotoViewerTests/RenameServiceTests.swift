import Foundation
import Testing
@testable import PhotoViewer

/// 一時フォルダに空のファイルを作ってリネームを試す
struct RenameServiceTests {
    final class TempDir {
        let url: URL
        init(_ files: [String]) throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("pv-rename-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for f in files {
                try Data(f.utf8).write(to: url.appendingPathComponent(f))
            }
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func u(_ name: String) -> URL { url.appendingPathComponent(name) }
        var names: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
        }
        func content(_ name: String) -> String? {
            (try? Data(contentsOf: u(name))).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    private func plan(_ dir: TempDir, targets: [String], options: RenameOptions,
                      metadata: [URL: PhotoMetadata] = [:]) -> RenamePlan {
        // アプリと同じく、走査結果の URL を使う（/var と /private/var の違いを避ける）
        let scan = FolderScanner.scan(dir.url)
        let byName = Dictionary(uniqueKeysWithValues: scan.items.map { ($0.name, $0.url) })
        let folder = scan.items[0].url.deletingLastPathComponent()
        let meta = Dictionary(uniqueKeysWithValues: metadata.compactMap { k, v in
            byName[k.lastPathComponent].map { ($0, v) }
        })
        return RenameService.plan(
            targets: targets.compactMap { byName[$0] }, folderItems: scan.items.map(\.url),
            sidecars: scan.sidecars, metadata: meta, modificationDates: [:],
            existingNames: [folder: Set(dir.names.map { $0.lowercased() })],
            options: options)
    }

    @Test func テンプレートの展開() {
        var o = RenameOptions()
        o.digits = 3
        let date = MetadataReader.parseExifDate("2025:08:15 10:30:05", offset: nil)
        let ctx = RenameService.TokenContext(originalBase: "IMG_0001", sequence: 7, date: date,
                                             camera: "Canon EOS R5", lens: nil)
        #expect(RenameService.render("{date}_{seq}", options: o, context: ctx) == "20250815_103005_007")
        #expect(RenameService.render("{date:yyyy-MM-dd}_{name}_{seq:5}", options: o, context: ctx)
            == "2025-08-15_IMG_0001_00007")
        #expect(RenameService.render("旅行_{camera}_{unknown}", options: o, context: ctx)
            == "旅行_Canon EOS R5_{unknown}")
        #expect(RenameService.render("a/b:c", options: o, context: ctx) == "a-b-c")
    }

    @Test func 連番でリネームしてサイドカーとペアも一緒に変わる() throws {
        let dir = try TempDir(["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp", "IMG_2.JPG"])
        var o = RenameOptions()
        o.template = "旅行_{seq:3}"
        let p = plan(dir, targets: ["IMG_1.CR3", "IMG_2.JPG"], options: o)
        #expect(p.canExecute)
        let journal = try RenameService.execute(p)
        #expect(dir.names == ["旅行_001.CR3", "旅行_001.JPG", "旅行_001.xmp", "旅行_002.JPG"])
        // 中身が入れ替わっていない
        #expect(dir.content("旅行_001.xmp") == "IMG_1.xmp")
        #expect(dir.content("旅行_002.JPG") == "IMG_2.JPG")

        // 取り消し
        _ = try RenameService.undo(journal)
        #expect(dir.names == ["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp", "IMG_2.JPG"])
        #expect(dir.content("IMG_1.CR3") == "IMG_1.CR3")
    }

    @Test func 名前の入れ替えができる() throws {
        let dir = try TempDir(["A.JPG", "B.JPG"])
        var o = RenameOptions()
        o.template = "{seq:1}"
        o.startNumber = 1
        // まず A→1, B→2 にしてから、逆順で 2→1, 1→2 に入れ替える
        _ = try RenameService.execute(plan(dir, targets: ["A.JPG", "B.JPG"], options: o))
        let p = plan(dir, targets: ["2.JPG", "1.JPG"], options: o)
        #expect(p.canExecute)
        _ = try RenameService.execute(p)
        #expect(dir.content("1.JPG") == "B.JPG")
        #expect(dir.content("2.JPG") == "A.JPG")
    }

    @Test func 既存ファイルとの衝突を検出する() throws {
        let dir = try TempDir(["A.JPG", "B.JPG", "旅行_1.JPG"])
        var o = RenameOptions()
        o.template = "旅行_{seq:1}"
        let p = plan(dir, targets: ["A.JPG"], options: o)
        #expect(!p.canExecute)
        #expect(p.problems.first?.problem == "同じ名前のファイルがすでにあります")
    }

    @Test func 変更後の名前の重複を検出する() throws {
        let dir = try TempDir(["A.JPG", "B.JPG"])
        var o = RenameOptions()
        o.template = "同じ名前"
        let p = plan(dir, targets: ["A.JPG", "B.JPG"], options: o)
        #expect(!p.canExecute)
        #expect(p.problems.count == 2)
    }

    @Test func 空の名前は実行できない() throws {
        let dir = try TempDir(["A.JPG"])
        var o = RenameOptions()
        o.template = "{date}"   // 日付がないので空になる
        let p = plan(dir, targets: ["A.JPG"], options: o)
        #expect(!p.canExecute)
    }

    @Test func ペアを分けるときはサイドカーをコピーする() throws {
        let dir = try TempDir(["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp"])
        var o = RenameOptions()
        o.template = "新_{seq:1}"
        o.includePairs = false
        let p = plan(dir, targets: ["IMG_1.JPG"], options: o)
        #expect(p.canExecute)
        let journal = try RenameService.execute(p)
        #expect(dir.names == ["IMG_1.CR3", "IMG_1.xmp", "新_1.JPG", "新_1.xmp"])
        _ = try RenameService.undo(journal)
        #expect(dir.names == ["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp"])
    }

    @Test func 拡張子の大文字小文字を変えられる() throws {
        let dir = try TempDir(["a.JPG"])
        var o = RenameOptions()
        o.template = "{name}"
        o.extensionCase = .lower
        let p = plan(dir, targets: ["a.JPG"], options: o)
        #expect(p.canExecute)
        _ = try RenameService.execute(p)
        #expect(dir.names == ["a.jpg"])
    }

    @Test func 撮影日を使う() throws {
        let dir = try TempDir(["A.JPG"])
        var m = PhotoMetadata()
        m.captureDate = MetadataReader.parseExifDate("2024:12:31 23:59:58", offset: nil)
        var o = RenameOptions()
        o.template = "{date:yyyyMMdd}_{seq:2}"
        let p = plan(dir, targets: ["A.JPG"], options: o, metadata: [dir.u("A.JPG"): m])
        #expect(p.rows.first?.destination.lastPathComponent == "20241231_01.JPG")
    }

    @Test func 途中で失敗したら元に戻す() throws {
        let dir = try TempDir(["A.JPG", "B.JPG"])
        // 計画を立てた後に、変更先の名前のファイルが現れた状況を作る
        var o = RenameOptions()
        o.template = "X{seq:1}"
        let p = plan(dir, targets: ["A.JPG", "B.JPG"], options: o)
        #expect(p.canExecute)
        try Data("邪魔".utf8).write(to: dir.u("X2.JPG"))
        #expect(throws: RenameError.self) { try RenameService.execute(p) }
        #expect(dir.names == ["A.JPG", "B.JPG", "X2.JPG"])
        #expect(dir.content("A.JPG") == "A.JPG")
    }
}
