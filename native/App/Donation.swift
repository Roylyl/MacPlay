import SwiftUI
import AppKit

private enum DonationMethod: String, CaseIterable, Identifiable {
    case wechat, alipay, alipayhk

    var id: String { rawValue }
    var title: String {
        switch self {
        case .wechat: return "微信支付"
        case .alipay: return "支付宝"
        case .alipayhk: return "AlipayHK"
        }
    }

    private static let images: [Self: NSImage] = Dictionary(uniqueKeysWithValues: allCases.compactMap { method in
        guard let url=Bundle.main.url(forResource:method.rawValue,withExtension:"jpg",subdirectory:"donation"),
              let image=NSImage(contentsOf:url) else {return nil}
        return (method,image)
    })

    var image: NSImage? { Self.images[self] }
}

struct MacPlayDonationView: View {
    @State private var selected: DonationMethod?
    private let paypalURL=URL(string:"https://paypal.me/RoyRoylyl")!

    var body: some View {
        Section(L("支持MacPlay")) {
            Text(L("感谢你支持MacPlay的持续开发。"))
            HStack(alignment:.top,spacing:12) {
                ForEach(DonationMethod.allCases) { method in
                    Button {selected=method} label: {
                        VStack(spacing:12) {
                            Text(L(method.title)).font(.headline)
                            DonationCodeImage(method:method)
                                .frame(height:240)
                            Label(L("点击放大"),systemImage:"arrow.up.left.and.arrow.down.right")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth:.infinity)
                        .padding(12)
                        .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
                        .contentShape(RoundedRectangle(cornerRadius:12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L(method.title))
                    .accessibilityHint(L("点击放大"))
                }
            }.padding(.vertical,8)
        }
        .sheet(item:$selected) { method in
            VStack(spacing:16) {
                HStack {
                    Text(L(method.title)).font(.title2.weight(.semibold))
                    Spacer()
                    Button(L("关闭")) {selected=nil}.keyboardShortcut(.cancelAction)
                }
                DonationCodeImage(method:method)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            .padding(24)
            .frame(width:500,height:620)
        }
        Section("PayPal") {
            HStack {
                Text("RoyRoylyl")
                Spacer()
                Link(destination:paypalURL) {
                    Label(L("通过PayPal捐赠"),systemImage:"arrow.up.right.square")
                }.buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct DonationCodeImage: View {
    let method: DonationMethod

    var body: some View {
        if let image=method.image {
            Image(nsImage:image).resizable().interpolation(.high).scaledToFit()
                .accessibilityLabel(L(method.title))
        } else {
            Label(L("收款码无法加载"),systemImage:"exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }
}
