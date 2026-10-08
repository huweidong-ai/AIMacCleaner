#!/usr/bin/env swift
import AppKit

// ─────────────────────────────────────────────────────────────
// AI Mac Cleaner app icon — "Sparkle Broom" (闪光扫帚) · v2 多彩版
//
// 概念：一个粗壮的白色「AI 四角闪光 + 扫帚」合一剪影，立在
// 明亮的多彩渐变圆角方块上（青 → 天蓝 → 靛 → 紫罗兰）。
// 实心填充、高对比、无细线 —— 即使缩到菜单栏 16px 也能一眼认出
// 「AI + 清理」。v2 相比 v1 的变化：
//   • 底色：深 Petrol Blue → 明亮多彩渐变（更明快、更活泼）
//   • 闪光：白色微暖渐变（白 → 淡琥珀），给 AI 元素一点暖色层次
//   • 扫帚头：底部改为圆弧扇形，更现代的「掸子」造型
//   • 帚缝：半透明深色（不依赖底色，兼容任意渐变底）
//   • 闪光背后加柔和光晕，强化 AI 发光感
//
// 输出：
//   1. Sources/IconGen/AIMacCleaner.png   (1024×1024 应用图标)
//   2. generated-icons/menu-bar-18/36/54.png  (菜单栏 template 单色)
//   3. generated-icons/icon-preview.png    (多尺寸可读性预览)
// ─────────────────────────────────────────────────────────────

// MARK: - 多彩渐变（青 → 天蓝 → 靛 → 紫罗兰）
let BG_STOPS: [(CGFloat, NSColor)] = [
    (0.00, NSColor(red: 0.176, green: 0.831, blue: 0.749, alpha: 1)), // #2DD4BF 青
    (0.35, NSColor(red: 0.220, green: 0.741, blue: 0.973, alpha: 1)), // #38BDF8 天蓝
    (0.70, NSColor(red: 0.506, green: 0.545, blue: 0.973, alpha: 1)), // #818CF8 靛
    (1.00, NSColor(red: 0.659, green: 0.333, blue: 0.969, alpha: 1)), // #A855F7 紫罗兰
]

// 闪光暖色渐变：白 → 淡琥珀
let SPARKLE_TOP = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)       // 白
let SPARKLE_BOT = NSColor(red: 1.0, green: 0.914, blue: 0.659, alpha: 1)   // #FFE9A8 淡琥珀

// 帚缝：半透明深靛，兼容任意底色
let SLIT_COLOR = NSColor(calibratedWhite: 0, alpha: 0.30)

// MARK: - 四角闪光路径（经典 sparkle，凹边，实心）
/// 生成以 (0,0) 为中心、外半径 R 的四角闪光（顶点朝上/右/下/左）。
func sparklePath(R: CGFloat, valleyFactor: CGFloat = 0.34) -> NSBezierPath {
    let p = NSBezierPath()
    let v = R * valleyFactor
    let d = v / CGFloat(sqrt(2))
    let T  = NSPoint(x: 0,  y: R)
    let Rt = NSPoint(x: R,  y: 0)
    let B  = NSPoint(x: 0,  y: -R)
    let L  = NSPoint(x: -R, y: 0)
    let ne = NSPoint(x: d,  y: d)
    let se = NSPoint(x: d,  y: -d)
    let sw = NSPoint(x: -d, y: -d)
    let nw = NSPoint(x: -d, y: d)
    p.move(to: T)
    p.curve(to: Rt, controlPoint1: ne, controlPoint2: ne)
    p.curve(to: B,  controlPoint1: se, controlPoint2: se)
    p.curve(to: L,  controlPoint1: sw, controlPoint2: sw)
    p.curve(to: T,  controlPoint1: nw, controlPoint2: nw)
    p.close()
    return p
}

// MARK: - 整幅「闪光扫帚」剪影（局部坐标，竖直立正）
/// 闪光在上，扫帚在下。柄用填充的圆角矩形表示（可整体 fill）。
/// 局部坐标约 y ∈ [-fanBottom, sparkleTop]，x ∈ [-R, R]。
func sparkleBroomGlyph(sparkleR: CGFloat,
                       handleTopToCenter: CGFloat,   // 闪光中心相对整体中心的高度
                       handleLength: CGFloat,
                       handleWidth: CGFloat,
                       fanTopHalfWidth: CGFloat,
                       fanBottomHalfWidth: CGFloat,
                       fanHeight: CGFloat) -> NSBezierPath {
    let shape = NSBezierPath()
    // 闪光
    let sparkleCY = handleTopToCenter + sparkleR
    let spPath = sparklePath(R: sparkleR)
    let spT = AffineTransform(translationByX: 0, byY: sparkleCY)
    spPath.transform(using: spT)
    shape.append(spPath)

    // 柄（填充圆角矩形）：从闪光底端向下到扫帚头顶
    let handleTop = sparkleCY - sparkleR
    let handleBottom = handleTop - handleLength
    let fanBottom = handleBottom - fanHeight
    let handleRect = NSBezierPath(roundedRect: NSRect(x: -handleWidth / 2, y: handleBottom,
                                                      width: handleWidth, height: handleLength),
                                  xRadius: handleWidth / 2, yRadius: handleWidth / 2)
    shape.append(handleRect)

    // 扫帚头：顶部平直 + 底部圆弧的扇形（现代「掸子」造型）
    let fan = NSBezierPath()
    fan.move(to: NSPoint(x: -fanTopHalfWidth, y: handleBottom))
    fan.line(to: NSPoint(x:  fanTopHalfWidth, y: handleBottom))
    // 右下侧边
    fan.line(to: NSPoint(x:  fanBottomHalfWidth, y: fanBottom + fanHeight * 0.42))
    // 底部圆弧：用三次曲线实现柔和圆底
    fan.curve(to: NSPoint(x: -fanBottomHalfWidth, y: fanBottom + fanHeight * 0.42),
              controlPoint1: NSPoint(x:  fanBottomHalfWidth * 0.92, y: fanBottom),
              controlPoint2: NSPoint(x: -fanBottomHalfWidth * 0.92, y: fanBottom))
    fan.close()
    shape.append(fan)
    shape.windingRule = .nonZero
    return shape
}

// MARK: - 渲染工具
func renderRGBA(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    return rep
}

func withContext(_ rep: NSBitmapImageRep, _ body: () -> Void) {
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    body()
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("✓ \(path) (\(data.count) bytes)")
}

func backgroundGradient() -> NSGradient {
    let colors = BG_STOPS.map { $0.1 }
    let locations = BG_STOPS.map { $0.0 }
    return NSGradient(colors: colors, atLocations: locations,
                      colorSpace: .deviceRGB)!
}

// ─────────────────────────────────────────────────────────────
// 1. 应用图标 1024×1024
let APP = 1024
let appRep = renderRGBA(size: APP)
withContext(appRep) {
    // 圆角多彩渐变底
    let rect = NSRect(x: 0, y: 0, width: CGFloat(APP), height: CGFloat(APP))
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: 225, yRadius: 225)
    backgroundGradient().draw(in: bgPath, angle: 135)

    // 闪光扫帚剪影（局部竖直），绕画布中心旋转 20°
    let glyph = sparkleBroomGlyph(sparkleR: 185,
                                  handleTopToCenter: 20,
                                  handleLength: 150,
                                  handleWidth: 38,
                                  fanTopHalfWidth: 52,
                                  fanBottomHalfWidth: 178,
                                  fanHeight: 230)
    // 旋转后平移（分两步变换，避免 concatenating API 差异）
    let rt = AffineTransform(rotationByDegrees: 20)
    glyph.transform(using: rt)
    let centerT = AffineTransform(translationByX: CGFloat(APP) / 2, byY: CGFloat(APP) / 2 + 6)
    glyph.transform(using: centerT)

    // 闪光中心（局部 0, 205）在最终画布上的位置 → 用于光晕定位
    var sparkleCenter = NSPoint(x: 0, y: 20 + 185)
    sparkleCenter = rt.transform(sparkleCenter)
    sparkleCenter = centerT.transform(sparkleCenter)

    // 闪光背后柔和光晕（白，径向渐隐）
    let glow = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.24),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    glow.draw(fromCenter: sparkleCenter, radius: 10,
              toCenter: sparkleCenter, radius: 330,
              options: [])

    // 扫帚 + 柄：纯白填充
    let broomPath = NSBezierPath()
    // 柄（填充圆角矩形）
    let handleTop: CGFloat = 20 + 185 - 185       // = 20
    let handleBottom: CGFloat = handleTop - 150   // = -130
    let fanBottom: CGFloat = handleBottom - 230   // = -360
    let handleRect = NSBezierPath(roundedRect: NSRect(x: -19, y: handleBottom,
                                                      width: 38, height: 150),
                                  xRadius: 19, yRadius: 19)
    broomPath.append(handleRect)
    // 扫帚头扇形
    let fan = NSBezierPath()
    fan.move(to: NSPoint(x: -52, y: handleBottom))
    fan.line(to: NSPoint(x:  52, y: handleBottom))
    fan.line(to: NSPoint(x:  178, y: fanBottom + 230 * 0.42))
    fan.curve(to: NSPoint(x: -178, y: fanBottom + 230 * 0.42),
              controlPoint1: NSPoint(x:  178 * 0.92, y: fanBottom),
              controlPoint2: NSPoint(x: -178 * 0.92, y: fanBottom))
    fan.close()
    broomPath.append(fan)
    broomPath.windingRule = .nonZero
    broomPath.transform(using: rt)
    broomPath.transform(using: centerT)
    NSColor.white.setFill()
    broomPath.fill()

    // 闪光：白色 → 淡琥珀 暖渐变（独立填充，营造「AI 发光」暖色层次）
    let sparkleOnly = sparklePath(R: 185)
    let spT = AffineTransform(translationByX: 0, byY: 20 + 185)
    sparkleOnly.transform(using: spT)
    sparkleOnly.transform(using: rt)
    sparkleOnly.transform(using: centerT)
    let spGrad = NSGradient(starting: SPARKLE_TOP, ending: SPARKLE_BOT)!
    spGrad.draw(in: sparkleOnly, angle: -70)

    // 帚缝：扫帚头局部 y∈[-380,-130]，叠 3 条半透明深色细线
    SLIT_COLOR.setStroke()
    for fx in [-70.0, 0.0, 70.0] {
        let n = NSBezierPath()
        n.move(to: NSPoint(x: fx, y: -340))
        n.line(to: NSPoint(x: fx, y: -180))
        n.lineWidth = 7
        n.lineCapStyle = .round
        let nrt = AffineTransform(rotationByDegrees: 20)
        n.transform(using: nrt)
        n.transform(using: centerT)
        n.stroke()
    }
}
writePNG(appRep, to: "Sources/IconGen/AIMacCleaner.png")

// ─────────────────────────────────────────────────────────────
// 2. 菜单栏 template 单色图标（黑 + alpha，macOS 自动适配深浅菜单栏）
func menuBarMarkPath() -> NSBezierPath {
    let shape = NSBezierPath()
    // 紧凑闪光：中心 (0, 3.4)，R=5.6
    let sp = sparklePath(R: 5.6, valleyFactor: 0.32)
    let t = AffineTransform(translationByX: 0, byY: 3.4)
    sp.transform(using: t)
    shape.append(sp)
    // 短柄（填充圆角矩形）
    let handle = NSBezierPath(roundedRect: NSRect(x: -0.7, y: -3.6, width: 1.4, height: 2.4),
                              xRadius: 0.7, yRadius: 0.7)
    shape.append(handle)
    // 扫帚尾：小梯形
    let fan = NSBezierPath()
    fan.move(to: NSPoint(x: -1.8, y: -3.6))
    fan.line(to: NSPoint(x:  1.8, y: -3.6))
    fan.line(to: NSPoint(x:  4.4, y: -6.6))
    fan.line(to: NSPoint(x: -4.4, y: -6.6))
    fan.close()
    shape.append(fan)
    shape.windingRule = .nonZero
    return shape
}

for s in [18, 36, 54] {
    let rep = renderRGBA(size: s)
    withContext(rep) {
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: s, height: s)).fill()
        let mark = menuBarMarkPath()
        // 缩放到画布 ~88% 高度，再居中
        let markHeight: CGFloat = 15.6
        let scale = CGFloat(s) * 0.88 / markHeight
        let sc = AffineTransform(scaleByX: scale, byY: scale)
        mark.transform(using: sc)
        let tr = AffineTransform(translationByX: CGFloat(s) / 2, byY: CGFloat(s) / 2 - 1)
        mark.transform(using: tr)
        NSColor.black.setFill()
        mark.fill()
    }
    writePNG(rep, to: "generated-icons/menu-bar-\(s).png")
}

// ─────────────────────────────────────────────────────────────
// 3. 多尺寸可读性预览
let pvSizes = [128, 64, 32, 16]
let canvasW = 200
let canvasH = 160
let previewRep = renderRGBA(size: canvasH * (pvSizes.count + 1))
withContext(previewRep) {
    NSColor(white: 0.97, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: previewRep.pixelsWide, height: previewRep.pixelsHigh)).fill()

    let fullPNG = appRep.representation(using: .png, properties: [:])!
    let fullImg = NSImage(data: fullPNG)!
    var y = previewRep.pixelsHigh - canvasH
    for s in pvSizes {
        let dst = NSRect(x: (canvasW - s) / 2, y: y + (canvasH - s) / 2, width: s, height: s)
        fullImg.draw(in: dst, from: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                     operation: .copy, fraction: 1.0)
        let lbl = NSAttributedString(string: "\(s)px",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.3, alpha: 1)])
        lbl.draw(at: NSPoint(x: canvasW + 8, y: y + (canvasH - 12) / 2))
        y -= canvasH
    }
    // 底部说明
    let cap = NSAttributedString(string: "AI Mac Cleaner — Sparkle Broom · Multicolor",
        attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.2, alpha: 1)])
    cap.draw(at: NSPoint(x: 10, y: 16))
}
writePNG(previewRep, to: "generated-icons/icon-preview.png")

print("DONE")
