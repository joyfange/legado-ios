import SwiftUI
import UIKit

enum AppIdentity {
    static let name = "墨卷阅读"
    static let slogan = "一卷在手，静享阅读"
    static let developer = "joyfange"
}

struct AboutView: View {
    private var name: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? AppIdentity.name }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    private var diagnosticSummary: String {
        "\(name) \(version) (\(build))\niOS \(UIDevice.current.systemVersion)\n数据库版本 \(LegadoDatabase.schemaVersion)"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image("BrandIcon").resizable().scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    Text(name).font(AppFontStyle.title2.weight(.semibold).themed)
                    Text(AppIdentity.slogan).font(AppFontStyle.subheadline.themed).foregroundStyle(.secondary)
                    Text("支持书源导入的 iOS 阅读应用")
                        .font(AppFontStyle.footnote.themed).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
                ReadingLabeledContent("版本", value: version)
                ReadingLabeledContent("构建", value: build)
                ReadingLabeledContent("系统", value: "iOS \(UIDevice.current.systemVersion)")
                ReadingLabeledContent("开发者", value: AppIdentity.developer)
                ReadingShareLink(item: diagnosticSummary) { Label("分享版本信息", systemImage: "square.and.arrow.up") }
            }.readingRowBackground()
            Section("免责协议") {
                Text("\(AppIdentity.name)不提供、内置或分发网络书源，也不提供在线书库。书源由用户自行从网络公开分享获取，或自行编写后导入；在线书籍及订阅内容由对应的第三方网站提供。")
                Text("书籍正文、封面、简介等内容的版权归原作者或合法权利人所有。书源可被导入、内容可被访问，不代表已获得版权授权；请仅在获得授权或法律允许的范围内使用，并支持正版阅读。")
                Text("第三方书源及其内容不受本应用控制，可能因网站调整、网络环境等原因失效。本应用不保证第三方内容的准确性、完整性、安全性或书源的持续可用性，请自行核实来源。")
                Text("用户应对自行导入的书源及使用行为负责，遵守适用法律法规和来源网站的使用规则，不得利用本应用侵犯他人权益、传播违法内容或未经授权复制、分发作品。")
                Text("如发现涉嫌侵权内容，请停止访问、删除相关书源及本地缓存，并向内容来源网站反馈。本协议不免除任何一方依法应承担的责任。")
            }.readingRowBackground()
            .font(AppFontStyle.footnote.themed)
            .lineSpacing(4)
            .textSelection(.enabled)
            Section("数据与隐私") {
                Text("书架、阅读进度、书源和诊断日志保存在本机。导入书源、阅读在线内容和刷新订阅时，会连接相应来源的网站。")
                Text("应用不会自动上传诊断日志；可在日志页面手动导出。")
                Text("应用不提供内置网络书源或在线书库。请使用你有权访问的内容与书源。")
            }.readingRowBackground().font(AppFontStyle.footnote.themed)
        }.readingThemedListBackground()
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
