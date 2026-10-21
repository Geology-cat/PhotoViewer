import CoreGraphics
import Testing
@testable import PhotoViewer

struct GridAndPreviewTests {
    @Test func 左右キーは行の端で次の行へ回り込む() {
        // 並び順の番号で 1 つ進むだけなので、行の右端（例：3 列なら 2）の次は次の行の左端（3）になる
        #expect(PhotoCollectionView.horizontalTarget(from: 2, delta: 1, count: 10) == 3)
        #expect(PhotoCollectionView.horizontalTarget(from: 3, delta: -1, count: 10) == 2)
        // 先頭・末尾では止まる
        #expect(PhotoCollectionView.horizontalTarget(from: 9, delta: 1, count: 10) == 9)
        #expect(PhotoCollectionView.horizontalTarget(from: 0, delta: -1, count: 10) == 0)
        // 何も選んでいなければ先頭か末尾から
        #expect(PhotoCollectionView.horizontalTarget(from: nil, delta: 1, count: 10) == 0)
        #expect(PhotoCollectionView.horizontalTarget(from: nil, delta: -1, count: 10) == 9)
    }

    @Test func 拡大率100パーセントは画像の1ピクセルを画面の1ピクセルにする() {
        // 6000×4000 の写真を 300×200 pt で全体表示、Retina（2 倍）の画面
        let z = ZoomGeometry.zoomSize(fit: CGSize(width: 300, height: 200), originalLongSide: 6000,
                                      percent: 100, displayScale: 2)
        #expect(z == CGSize(width: 3000, height: 2000))
        let half = ZoomGeometry.zoomSize(fit: CGSize(width: 300, height: 200), originalLongSide: 6000,
                                         percent: 50, displayScale: 2)
        #expect(half == CGSize(width: 1500, height: 1000))
    }

    @Test func 小さな画像でもクリックすれば大きくなる() {
        let z = ZoomGeometry.zoomSize(fit: CGSize(width: 300, height: 200), originalLongSide: 400,
                                      percent: 100, displayScale: 2)
        #expect(z == CGSize(width: 600, height: 400))
    }

    @Test func クリックした場所が拡大後も同じ位置に来る() {
        let box = CGSize(width: 400, height: 300), fit = CGSize(width: 400, height: 300)
        let zoom = CGSize(width: 1600, height: 1200)   // 4 倍
        let p = CGPoint(x: 300, y: 150)                  // 中心から右へ 100
        let o = ZoomGeometry.offsetKeeping(p, in: box, fit: fit, zoom: zoom)
        // 中心から 100 の点は拡大後 400 の位置になるので、-300 ずらすと元の位置に戻る
        #expect(o == CGSize(width: -300, height: 0))
    }

    @Test func ずらす量は画像の端が枠に入らない範囲に制限する() {
        let box = CGSize(width: 400, height: 300)
        let size = CGSize(width: 1600, height: 1200)
        #expect(ZoomGeometry.clamp(CGSize(width: -5000, height: 5000), size: size, rotation: 0, in: box)
                == CGSize(width: -600, height: 450))
        // 90° 回転していると幅と高さが入れ替わる
        #expect(ZoomGeometry.clamp(CGSize(width: -5000, height: 5000), size: size, rotation: 90, in: box)
                == CGSize(width: -400, height: 650))
        // 枠より小さければ動かない
        #expect(ZoomGeometry.clamp(CGSize(width: 50, height: 50), size: CGSize(width: 200, height: 100),
                                   rotation: 0, in: box) == .zero)
    }
}
