# 开发、部署与维护

[项目首页](../README.md) · [AI Passport 指南](AI_PASSPORT.md) · [发布验证](VALIDATION.md)

## 运行结构

这是本机菜单栏应用，不需要另部署服务器。Swift/AppKit/SwiftUI 负责界面、登录自启、BLE、宠物传输和本机听写；应用内嵌的 Python 引擎管理提醒规则、Codex 本地事件、输出设备和账号用量。

```text
本机 Codex Hooks / 本地事件 → Python 提醒引擎 → Mac 扬声器
                                      ↓
                        Swift 配件服务 ⇄ BLE ⇄ AI Passport
                              ↓
                  Apple 本机语音模型 → 当前输入框（不发送）
```

AI Passport 使用应用专用的 BLE 服务，不能用普通系统扬声器/麦克风选择代替连接。任务、用量、设置、听写和图片上传分通道处理；音频及紧急提醒优先于后台图片传输；演示模式开启时暂停图片传输。

## 演示翻页实现

电脑端 `0.10.0-presenter.1` 与工牌 `0.4.0-presenter` 复用同一加密 BLE 连接。固件的长按下键手势和短按松手事件发给 `PassportPresenter.swift`；它校验启动会话、连接 epoch、序号、短时凭据、前台目标和输入权限，再发送完整的左右方向键事件。它不读取幻灯片内容、放映状态或实际页码，也不注册全局按键监听。

演示静音通过八秒运行时租约续期，提醒引擎确认静音后才允许翻页。断连、休眠、应用重启会结束模式，不保存到长期偏好或补发按键。工牌通过直接绘制遥控区和共享互斥页面标签保留32 KiB LVGL配置。协议与控件状态见 [演示模式](PRESENTATION_MODE.md) 及 [固件协议说明](../firmware/ai-passport/docs/development/presentation-mode.zh_CN.md)。

## 目录与复现

- `src/`：Mac GUI、配件协议、听写/图片处理、Python 引擎及 Hook 安装器。
- `tests/`：Python 回归、Swift 协议/音频/图片/剪贴板测试。
- `scripts/build.py`：生产应用、universal 二进制、内嵌 Python、签名与打包。
- `scripts/verify_native.py`：隔离测试，使用生成图片和独立临时剪贴板，不录音、不连 BLE。
- `scripts/verify_app.py`：移动路径、干净 PATH、运行时、签名和配置持久化。
- `scripts/verify_passport_engine.py`：打包后的引擎、模拟工牌应答及独立设置迁移；它不等于真实 BLE 测试。
- `scripts/render_ui.py`：在临时独立应用中渲染真实 SwiftUI 视图的演示状态，不启动生产引擎。
- `firmware/ai-passport/`：可独立构建的 AI Passport 固件快照，内含 BSP、默认资源、依赖锁、完整验证工具与项目技能。

需要 macOS、Xcode Command Line Tools（macOS 26 SDK）、Python 3.11+ 和下载运行时的网络访问：

```sh
PYTHONPATH=src python3 -m unittest discover -s tests
python3 scripts/verify_native.py
python3 scripts/build.py --package
python3 scripts/verify_app.py '.build/Codex 语音提醒.app'
python3 scripts/verify_passport_engine.py '.build/Codex 语音提醒.app'
```

普通用户不需要安装以上开发依赖。构建脚本中的 Python 运行时版本与 SHA-256 固定在 `scripts/python-runtime.json`，只解包到应用内，不运行全局安装器。

构建产物在 `.build/` 和 `dist/`，均不提交 Git。默认临时签名；`--identity` 可选择已有签名身份，但这不会自动完成 Apple 公证。带有 Developer ID 的分发还需单独完成 hardened runtime、entitlements、公证和 Gatekeeper 验收，本版不宣称已完成这些步骤。

## 配件固件

固件来源为 FoloToy AI Passport 的明确提交加本项目的 Codex 配件实现，来源及变更见 [固件 README](../firmware/ai-passport/README.zh_CN.md)。固件构建要求 ESP-IDF 5.5.3，遵循目录内 `AGENTS.md` 和 `tools/validate.sh`。

发布文件包含完整镜像以及分段镜像、`flash_args`、分区信息、校验值；匹配 ELF/MAP 仅保留本地，避免不必要的调试资料公开。源码和测试可用于复现，编译时间/路径等元数据可能使自行构建的字节和发布包不同，不能仅凭版本名替代校验。

当前固件保留 NVS、PHY、factory、2 MiB 宠物资源分区。完整镜像从 `0x0` 写入可能重置存储设置；分段升级只在分区已确认兼容后使用。合并镜像校验工具会验证偏移、边界、不重叠和镜像头，构建不会自动操作 USB。

## 数据边界

`~/Library/Application Support/CodexVoice/` 保存设置、受限提醒元数据、事件队列、恢复检查点和宠物缓存，生产数据不放进应用包或源码仓库。

- **观察器**：只合并本工具的五项 Hook，备份原配置，不写信任记录、不改变审批权限。`PreToolUse` 关注结构化提问；审批和后续处理由对应事件及本地状态核对。
- **应用授权兼容识别**：默认关闭，由用户开启并授权辅助功能后在后台只读识别 Codex 已打开窗口内的真实应用授权卡片。跳过编辑框，只输出应用名及卡片存续，不保存聊天正文或截图，不激活应用、不点击审批。当前界面来源的提醒不恢复为历史待办。见 [行为与权限](APPROVAL_COMPATIBILITY.md)。
- **账号用量**：通过官方 Codex App Server 调用初始化、`account/read`、`account/rateLimits/read`。不自行读取/保存登录令牌，快照不含邮箱或接口原始响应；账号比较信息仅在内存中哈希处理。用量查询不启动模型任务。
- **恢复**：`reminder-state.json` 等保留必要任务 ID、有限标题及事件读取位置，采用受限权限和原子替换。无法核对的提醒保留卡片、暂不自动播报。
- **听写**：只处理工牌送来的有限长度音频，录音 ID、序号和尾包完整性检查后使用本机模型。音频和保留文字在进程内；退出应用不会持久恢复未输入的听写文字。
- **落字**：在按住时绑定前台应用、输入框、光标和原稿，焦点改变时不自动改写新目标。临时粘贴后核对结果，避免重复输入；尽力恢复原剪贴板，新复制内容优先。诊断文件只记录阶段、长度、权限布尔值等，不记录识别文字。
- **演示翻页**：只匹配前台应用身份并发送受限翻页键；本地诊断记录模式、目标类别、接受状态与发送次数，不保存幻灯片内容或页码。演示期间保留待处理任务，暂缓播报与自动弹面板，不改原有长期免打扰或输出开关。
- **宠物**：读取 `~/.codex/config.toml` 的选中 ID 和必要的宠物元数据，内置包/local pet/当前图像缓存。图像限定大小、尺寸与来源；不读取 Cookie、认证文件，不持久保存签名 URL。转换资源按身份/格式/哈希绑定，完整传输校验后切换，旧资源保留到提交成功。
- **外链**：订阅卡片只打开 `https://slashx.shop/`，不加账号参数；不会替用户付款或兑换。

首次仅在启用配件时需要蓝牙权限；听写及可选的应用授权识别额外需要辅助功能/设备控制权限。按住听写用本机 SpeechAnalyzer，不是服务器 SFSpeechRecognizer，不申请 Mac 麦克风权限。模型资源首次安装由系统处理，可能需要网络。

## 安装、启动与升级

生产应用保持 `/Applications/Codex 语音提醒.app`；Hook 与登录启动项引用该路径。设置位于应用包外，覆盖应用不删除设置。更新临时签名构建时，macOS 的输入权限可能需要移除旧项后重新添加同一路径的新应用。

登录启动由用户在设置中开启，LaunchAgent 为 `local.rico.CodexVoice.login`，只运行本应用的 `--background` 模式。GUI 管理一个配套引擎；异常时有限重试。收起面板与退出应用不同，退出会结束所管理的服务。

开发测试使用独立状态目录；不要同时运行两个生产引擎指向同一运行目录。不要把本机 `settings.json`、Hook 信任文件、宠物签名地址、设备配对信息、录音或完整聊天日志提交仓库。

## 代码同步与发布

代码与文档可以先同步到 GitHub，安装包仍按已发布 tag 提供。更新 README 不会为旧安装包增加功能；源码新能力和公开下载版本必须明确区分。只有发行新套件时才执行以下发布步骤。

1. 核对版本、变更、源码和既有用户设置迁移；运行 Mac 测试/构建与固件完整 gate。
2. 检查公开文件列表和敏感内容；只选择源码、公开文档与演示截图。保留第三方许可。
3. 将 Mac DMG/ZIP、固件完整镜像/固件 ZIP、说明和 SHA-256 上传到同一个 GitHub Release。
4. 让下载附件与发布 tag 中的源码、文档版本一致；不要静默覆盖已公开的同名资产。
5. 实际下载并校验上传后的附件，确认 README 图片、文档和下载链接可用。新建 PR 时按应用要求关联到当前任务。

本版验证结论与边界在 [VALIDATION.md](VALIDATION.md)，日常使用以 [README](../README.md) 和 [AI Passport 指南](AI_PASSPORT.md) 为准。
