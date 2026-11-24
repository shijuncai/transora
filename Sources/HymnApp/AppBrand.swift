import Foundation

/// 产品品牌。内部 bundle identifier 与 Application Support 数据目录保持原值，
/// 避免改名导致用户已保存的模型目录偏好、历史记录和术语库丢失。
///
/// v0.8.7 起对外品牌为「译澜 TransOra」：中文名 译澜，英文名 TransOra，
/// 图标是透明底的蓝紫渐变 TO（见 Assets/TransOra.icns）。
enum AppBrand {
    static let chineseName = "译澜"
    static let englishName = "TransOra"
    static let displayName = "译澜"
    static let fullName = "译澜 TransOra"
    /// 版本号**以 Info.plist 为唯一来源**。
    ///
    /// 踩过的坑：版本号曾经硬编码在这里，打包脚本另写一份 `CFBundleShortVersionString`，
    /// 两处不同步就会出现「Info.plist 是 0.8.1、关于窗口还显示 0.7.12」。
    /// 现在运行时优先读 bundle 里的值，只有直接跑 `.build/debug/HymnTranslate`
    /// （裸可执行文件没有 Info.plist）才回退到下面的常量。
    static let version: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !value.isEmpty {
            return value
        }
        return fallbackVersion
    }()

    /// 无 bundle 场景的回退值。必须与 `Scripts/make-app.sh` 的 `VERSION` 一致，
    /// `Scripts/make-release.sh` 的「2b/8 版本一致性」会强制校验，不一致直接中断发布。
    static let fallbackVersion = "0.8.7"
    static let tagline = "本机 AI 翻译"
    static let privacy = "所有翻译在本机完成，文本不会离开这台 Mac。"
    static let bundleIdentifier = "com.hymntranslate.macos"
}
