<p align="center"><img src="assets/icons/mac/macplay.iconset/icon_128x128.png" width="104" alt="MacPlay应用图标"></p>

<h1 align="center">MacPlay</h1>

<p align="center">在Mac上显示和操作iPhone的CarPlay界面，支持USB直连与局域网无线连接。</p>

<p align="center">
  <a href="scripts/package-native.sh"><img src="https://img.shields.io/badge/version-1.2.3-2563eb?style=flat-square" alt="版本1.2.3"></a>
  <a href="#使用条件"><img src="https://img.shields.io/badge/platform-macOS%2014%2B-555555?style=flat-square" alt="运行平台"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-2563eb?style=flat-square" alt="项目许可"></a>
</p>

<p align="center">
  <a href="https://github.com/Roylyl/MacPlay/releases"><img src="https://img.shields.io/github/downloads/Roylyl/MacPlay/total?style=flat-square&amp;label=downloads&amp;color=2563eb" alt="发行附件累计下载量"></a>
  <a href="https://github.com/Roylyl/MacPlay/stargazers"><img src="https://img.shields.io/github/stars/Roylyl/MacPlay?style=flat-square&amp;label=stars&amp;color=2563eb" alt="GitHub Star数"></a>
  <a href="https://github.com/Roylyl/MacPlay/forks"><img src="https://img.shields.io/github/forks/Roylyl/MacPlay?style=flat-square&amp;label=forks&amp;color=555555" alt="GitHub Fork数"></a>
  <a href="https://github.com/Roylyl/MacPlay/issues"><img src="https://img.shields.io/github/issues/Roylyl/MacPlay?style=flat-square&amp;label=issues&amp;color=555555" alt="开放Issue数"></a>
  <a href="https://github.com/Roylyl/MacPlay/pulls"><img src="https://img.shields.io/github/issues-pr/Roylyl/MacPlay?style=flat-square&amp;label=pull%20requests&amp;color=555555" alt="开放Pull Request数"></a>
  <a href="https://github.com/Roylyl/MacPlay/commits"><img src="https://img.shields.io/github/last-commit/Roylyl/MacPlay?style=flat-square&amp;label=last%20commit&amp;color=555555" alt="最近提交时间"></a>
</p>

<p align="center"><a href="#快速入门">快速入门</a> · <a href="#主要功能">主要功能</a> · <a href="#其他平台">其他平台</a> · <a href="#从源码构建">源码构建</a> · <a href="#来源与许可">来源与许可</a></p>

## 快速入门

### 使用条件

- macOS14及以上，Apple Silicon或Intel处理器。
- 支持CarPlay的iPhone；有线需要USB数据线，无线需要蓝牙与允许设备互访的局域网，iPhone使用Wi-Fi接入。
- 安装包包含所需运行组件，无需另装开发工具。

### 安装

前往[GitHubReleases](https://github.com/Roylyl/MacPlay/releases)，根据“苹果菜单→关于本机”中的芯片信息选择安装包：

| Mac类型 | 安装包 |
| --- | --- |
| AppleM系列 | 名称以`arm64.dmg`结尾 |
| Intel | 名称以`x86_64.dmg`结尾 |

打开DMG，将MacPlay拖入“应用程序”后启动。若macOS拦截，在“系统设置→隐私与安全性”中允许打开。当前包采用本地签名，未经过Apple公证。

首次启动自动准备内置认证文件，默认1280×720、60fps，并优先使用内建显示器。更新前退出旧版，再替换应用，原有设置会保留。详细步骤见[发行版使用教程](docs/发行版使用教程.md)。

### 有线CarPlay

1. 用USB数据线连接iPhone与Mac，解锁iPhone并完成“信任此电脑”。
2. 在“连接”页选择“有线CarPlay”，多台设备同时接入时选择目标iPhone。
3. 点击“启动接收”，在iPhone上确认CarPlay提示。

有线无需填写Wi-Fi信息。可在“连接→应用”开启“USB接入时自动启动CarPlay”，让MacPlay运行期间自动响应iPhone接入；已指定设备时只响应该设备。

### 无线CarPlay

1. Mac和iPhone接入同一个允许设备互访的局域网，选择“无线CarPlay”。Mac可连接Wi-Fi，也可通过以太网接入同一路由器。
2. Mac使用Wi-Fi时，点击“读取当前网络”并填写密码，也可点击“读取已保存密码”。Mac使用以太网时，手动填写iPhone所在Wi-Fi的SSID、共享密码和实际信道。
3. 打开蓝牙设置，在iPhone上选择Mac的系统名称，在两端确认配对码。
4. 在MacPlay选择目标iPhone，点击“启动接收”，在iPhone上允许CarPlay连接。

MacPlay通过蓝牙建立连接，再通过局域网传输音视频，不创建热点。读取Wi-Fi名称需要定位权限，读取密码可能要求钥匙串授权。企业802.1X和网页登录认证不适用于此连接方式，请使用个人Wi-Fi或USB连接。

## 主要功能

- 独立CarPlay窗口，支持鼠标点击、拖动和触控板双指滚动。
- 选择内建或外接显示器，按比例调整窗口，也可使用固定物理像素或全屏模式。
- 实时调整媒体/通话音量、切换音频设备；向Mac控制中心同步歌曲、封面、播放状态和进度。
- 记住上次连接的iPhone，支持USB接入自动启动，以及可选的无线断线自动重连。
- 视频停滞或中断时尝试恢复，提供实际帧率、视频尺寸和音频格式。
- 提供简体中文、繁體中文、English和跟随Mac系统语言；支持菜单栏后台运行。
- 在“关于”页检查更新、导出TXT日志或JSON诊断快照。

## 无线设置

网络接口默认自动选择，多网卡环境可改为“手动选择网卡（高级）”。手动选择会保留，接口断开时不会擅自换到其他网卡。所选接口需要可用IPv4或链路本地IPv6地址，路由器须允许Mac与iPhone互访。

启动连接前会刷新同一Wi-Fi的信道和BSSID，适应Mesh接入点变化。Mac走以太网或需要指定接入点时，可在“共用Wi-Fi→高级网络设置”填写BSSID，通常留空即可。切换SSID后需重新填写或读取密码；读取失败原因显示在按钮下方，同一网络已有的密码会保留。

“无线连接被动断开时自动重连”默认关闭。开启后，仅对已成功连接后意外断开的iPhone自动回连，间隔依次为5、10、20、30、60秒，之后保持60秒。主动停止、确认断开、退出或关闭开关都会取消重连；首次连接失败不会自动重试。

## 显示与声音

“显示”页提供1280×720、1920×1080、2560×1440、自定义宽高和屏幕原生像素模式。默认窗口适配所选屏幕，可等比例调整大小，不改变向iPhone请求的分辨率。更改显示设置后点击“应用并重新连接”。

“严格按屏幕物理像素显示”默认关闭；开启后窗口大小固定，仍可移动。原生像素模式全屏并避开刘海。这两种模式需要等待显示器参数读取完成；读取失败时可刷新，或先使用普通窗口模式。

帧率可选30/60/90/120fps，默认60fps。120fps启动失败后依次尝试90fps和60fps，90fps失败后尝试60fps，只影响本次连接。实际输出取决于iPhone、网络和解码能力，可在“显示→流畅度→接收统计”查看。静态画面下帧率可能降低，解码帧率也不等于屏幕刷新率。

CarPlay的“设置→显示屏→智能缩放显示”会影响图标、文字和渲染尺寸。希望按所选像素显示时，可在CarPlay内关闭，再应用并重新连接。MacPlay不提供缩放倍率。

“音频”页可实时调整媒体/通话音量、切换输入/输出设备，查看音频格式。设备拔出后回退系统默认设备，无需重新连接CarPlay。Mac控制中心显示歌曲、封面和进度；播放器提供时长并允许跳转时，可拖动系统进度条。本版不提供独立歌词同步。

## 窗口与后台

收到画面后自动打开CarPlay窗口，鼠标移到画面顶部可显示悬浮标题栏。关闭画面时先确认断开，断开后回到连接主页。主窗口与CarPlay共用MacPlay的Dock入口；点击CarPlay中的MacPlay图标可打开主窗口。

在“连接→应用→关闭主窗口时”选择“每次询问”“保持后台运行”或“退出MacPlay”。新安装默认询问，更新安装保留原行为。后台运行时可从菜单栏图标打开窗口、启动/停止接收或退出；后台运行不等于开机启动。

“连接→应用”也可切换简体中文、繁體中文、English或跟随Mac系统语言，CarPlay内部语言仍跟随iPhone。

## 关于、更新与日志

在“关于”页查看版本和运行架构，检查GitHub正式发行版。自动检查默认开启，启动时检查，持续运行时每两小时静默检查。MacPlay按芯片选择安装包，通过Rosetta运行时也优先提供M系列版。更新经浏览器下载，退出旧版再替换应用，不自动安装。

在“关于→日志”导出TXT日志或JSON诊断快照。JSON附带版本、连接状态和媒体统计，方便反馈问题。导出会过滤密码、密钥、IP地址和常见设备标识，不包含设置文件或认证材料；发送前请查看内容。

## 认证与数据

1.2.3内置实验性认证材料，首次启动不覆盖本机已有身份。也可在“关于→认证文件→导入认证文件”选择匹配且获准使用的`identity.pk8`与`certificate.p7b`；普通Apple开发者签名证书不能替代配件认证。材料来源见[认证来源](assets/authentication/SOURCE.txt)。公开下载不等于取得再分发授权，公开分发前应确认材料权利。

设置、Wi-Fi密码、设备记录与配对身份保存在本机应用支持目录，不上传到服务器。定位权限用于读取Wi-Fi信息，蓝牙/本地网络用于连接，麦克风用于通话和语音。

## 从源码构建

需要macOS、Xcode命令行工具、Node.js、pnpm、Rust、pkg-config及GStreamer开发SDK。将SDK的`lib/pkgconfig`加入`PKG_CONFIG_PATH`，在仓库根目录执行：

~~~sh
pnpm install
pnpm run build
~~~

默认按本机架构构建；指定架构时选择一条命令：

~~~sh
# AppleM系列
pnpm run build -- --arch=arm64
# Intel
pnpm run build -- --arch=x64
~~~

生成`dist/MacPlay.app`和`dist/MacPlay-1.2.3-<arch>.dmg`，架构为`arm64`或`x86_64`，包含本地签名和运行组件。

## 更新日志

1.2.3主要改进无线连接和音视频恢复，新增设备实时切换、接收统计、JSON诊断与主窗口关闭选项。详见[1.2.3发行说明](docs/RELEASE-1.2.3.md)和[完整更新日志](CHANGELOG.md)。

## 其他平台

| 项目 | 平台 | 连接方式 |
| --- | --- | --- |
| [WinPlay](https://github.com/Roylyl/WinPlay) | Windows10/11x64 | 移动热点或局域网无线CarPlay |
| [AndroidPlay](https://github.com/Roylyl/AndroidPlay) | Android9及以上 | 系统热点与蓝牙连接iPhone |

## 来源与许可

感谢[Artist-x的PR#6](https://github.com/Roylyl/MacPlay/pull/6)提供悬浮标题栏和后台窗口恢复改进，感谢[drewpall的PR#1](https://github.com/Roylyl/MacPlay/pull/1)提供Intel支持基础实现。

网络发现、连接可靠性和网络设置交互参考同系列[WinPlay](https://github.com/Roylyl/WinPlay)。

MacPlay基于[LIVI](https://github.com/f-io/LIVI)，参考[DiPlay](https://github.com/shihabal3amri/DiPlay)，保留LasseHeitgres及贡献者的版权和许可声明，见[NOTICE](NOTICE)。项目沿用GPL-3.0-or-later，见[LICENSE](LICENSE)；运行库许可位于`assets/licenses`与`assets/gstreamer/LICENSES`。

第三方组件、认证文件和商标分别适用各自权利条件。MacPlay是独立衍生项目，不代表Apple或上游作者，不声称获得MFi认证。分发修改版时应保留声明并提供适用许可证要求的对应源码与构建资料。
