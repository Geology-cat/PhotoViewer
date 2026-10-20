import Foundation

/// レーティングと現像済みフラグ
struct PhotoTags: Hashable, Sendable {
    /// 0 = なし、1〜5 = ★の数、-1 = リジェクト（Bridge と同じ）
    var rating: Int = 0
    var developed: Bool = false

    static let empty = PhotoTags()
}

enum XMPError: LocalizedError {
    case invalidXML(String)
    case noDescription

    var errorDescription: String? {
        switch self {
        case .invalidXML(let s): "XMP ファイルを解釈できません：\(s)"
        case .noDescription: "XMP ファイルに rdf:Description がありません"
        }
    }
}

/// サイドカーへの書き込みを 1 件ずつ順番に行う（同じファイルへの同時書き込みで内容が失われるのを防ぐ）
actor SidecarWriter {
    static let shared = SidecarWriter()

    /// 各サイドカーに change を適用する。失敗したものの (URL, 理由) を返す
    func update(_ urls: [URL], change: @Sendable (inout PhotoTags) -> Void) -> [(URL, String)] {
        var failed: [(URL, String)] = []
        for u in urls {
            do {
                try XMPSidecar.update(at: u, change: change)
            } catch {
                failed.append((u, error.localizedDescription))
            }
        }
        return failed
    }
}

/// XMP サイドカー（<ベース名>.xmp）の読み書き
/// 既存のサイドカーは XML として読み込み、対象の項目だけを書き換えて他の情報（Lightroom の現像設定など）は残す
enum XMPSidecar {
    static let rdfNS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let xmpNS = "http://ns.adobe.com/xap/1.0/"
    static let pvNS = "https://github.com/Geology-cat/PhotoViewer/ns/1.0/"

    // MARK: 読み込み

    /// サイドカーを読む。ファイルがなければ nil
    static func read(from url: URL) throws -> PhotoTags? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> PhotoTags {
        let doc = try document(from: data)
        var tags = PhotoTags()
        for desc in descriptions(in: doc) {
            if let v = value(of: "Rating", ns: xmpNS, in: desc), let d = Double(v), d.isFinite {
                tags.rating = max(-1, min(5, Int(d)))
            }
            if let v = value(of: "Developed", ns: pvNS, in: desc) {
                tags.developed = v.lowercased() == "true"
            }
        }
        return tags
    }

    // MARK: 書き込み

    /// サイドカーに書く（既存のファイルがあれば対象の項目だけ書き換える）
    static func write(_ tags: PhotoTags, to url: URL, now: Date = Date()) throws {
        let existing = try? Data(contentsOf: url)
        let data = try updated(existing, with: tags, now: now)
        try data.write(to: url, options: .atomic)
    }

    /// 既存のサイドカーを読み、change で変更して書き戻す。変更後の値を返す
    @discardableResult
    static func update(at url: URL, now: Date = Date(), change: (inout PhotoTags) -> Void) throws -> PhotoTags {
        let existing = try? Data(contentsOf: url)
        var tags = try existing.map(parse) ?? PhotoTags()
        change(&tags)
        let data = try updated(existing, with: tags, now: now)
        try data.write(to: url, options: .atomic)
        return tags
    }

    /// XMP データを書き換えた結果を返す（existing が nil なら新規作成）
    static func updated(_ existing: Data?, with tags: PhotoTags, now: Date = Date()) throws -> Data {
        let doc = try existing.map(document(from:)) ?? newDocument()
        let descs = descriptions(in: doc)
        guard let first = descs.first else { throw XMPError.noDescription }

        // 既存の値はすべての Description から消してから、最初の Description に書く
        for d in descs {
            remove("Rating", ns: xmpNS, from: d)
            remove("Developed", ns: pvNS, from: d)
        }
        if tags.rating != 0 {
            set("Rating", ns: xmpNS, preferredPrefix: "xmp", value: String(tags.rating), on: first)
        }
        if tags.developed {
            set("Developed", ns: pvNS, preferredPrefix: "pv", value: "True", on: first)
        }
        // Lightroom などが変更を検知できるよう、メタデータの更新日時を入れる
        for d in descs { remove("MetadataDate", ns: xmpNS, from: d) }
        set("MetadataDate", ns: xmpNS, preferredPrefix: "xmp", value: iso8601(now), on: first)

        return doc.xmlData(options: [.nodePreserveWhitespace, .nodePreserveCDATA])
    }

    // MARK: - XML 操作

    private static func document(from data: Data) throws -> XMLDocument {
        do {
            return try XMLDocument(data: data, options: [.nodePreserveWhitespace, .nodePreserveCDATA])
        } catch {
            throw XMPError.invalidXML(error.localizedDescription)
        }
    }

    private static func newDocument() -> XMLDocument {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="PhotoViewer">
         <rdf:RDF xmlns:rdf="\(rdfNS)">
          <rdf:Description rdf:about=""
            xmlns:xmp="\(xmpNS)"
            xmlns:pv="\(pvNS)">
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """
        // 固定の文字列なので失敗しない
        return try! XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
    }

    /// すべての rdf:Description 要素
    static func descriptions(in doc: XMLDocument) -> [XMLElement] {
        var result: [XMLElement] = []
        func walk(_ node: XMLNode) {
            if let e = node as? XMLElement {
                if e.localName == "Description" && e.uri == rdfNS { result.append(e) }
                e.children?.forEach(walk)
            }
        }
        if let root = doc.rootElement() { walk(root) }
        return result
    }

    /// 属性（xmp:Rating="3"）または子要素（<xmp:Rating>3</xmp:Rating>）の値
    private static func value(of name: String, ns: String, in desc: XMLElement) -> String? {
        if let a = desc.attribute(forLocalName: name, uri: ns) { return a.stringValue }
        return desc.elements(forLocalName: name, uri: ns).first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func remove(_ name: String, ns: String, from desc: XMLElement) {
        if let a = desc.attribute(forLocalName: name, uri: ns), let n = a.name {
            desc.removeAttribute(forName: n)
        }
        for child in desc.elements(forLocalName: name, uri: ns) {
            if let i = desc.children?.firstIndex(where: { $0 === child }) {
                desc.removeChild(at: i)
            }
        }
    }

    private static func set(_ name: String, ns: String, preferredPrefix: String, value: String, on desc: XMLElement) {
        let prefix = ensureNamespace(ns, preferredPrefix: preferredPrefix, on: desc)
        let attr = XMLNode.attribute(withName: "\(prefix):\(name)", uri: ns, stringValue: value)
        desc.addAttribute(attr as! XMLNode)
    }

    /// 名前空間の接頭辞を返す。宣言されていなければ Description に宣言を追加する
    private static func ensureNamespace(_ ns: String, preferredPrefix: String, on desc: XMLElement) -> String {
        if let p = desc.resolvePrefix(forNamespaceURI: ns), !p.isEmpty { return p }
        // 同じ接頭辞が別の URI で使われていたら番号を付ける
        var prefix = preferredPrefix
        var n = 1
        while let used = desc.resolveNamespace(forName: "\(prefix):x")?.stringValue, used != ns {
            n += 1
            prefix = "\(preferredPrefix)\(n)"
        }
        desc.addNamespace(XMLNode.namespace(withName: prefix, stringValue: ns) as! XMLNode)
        return prefix
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }
}
