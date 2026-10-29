# 界面图片

本目录使用真实界面组件和隔离的演示数据，不含个人聊天、账号、录音或设备标识。昵称为 Codex，百分比、电量和提醒数量均为示例；图片不是硬件实拍，也不代表某位用户的实际读数。

| 文件 | 来源 | 展示内容 |
| --- | --- | --- |
| `home.png`、`tasks.png`、`usage.png` | `scripts/render_ui.py` 的真实 SwiftUI 视图 | 首页、任务、用量详情 |
| `passport.png` | 同一 SwiftUI 渲染器 | 当前源码的 AI Passport 配件设置 |
| `presentation-settings.png` | 同一渲染器的 `presenter` 场景 | 演示模式开关、软件选择与交互说明 |
| `passport-presentation.png` | 固件 `tools/render_pocket_ui.py` 的真实 LVGL 控件 | 深色遥控页面与就绪状态 |
| `passport-presentation-paused.png` | 同一 LVGL 渲染器 | 焦点不匹配时的暂停状态 |

Mac 截图复现：在仓库根目录运行 `python3 scripts/render_ui.py`。默认只使用随仓库提供的演示形象；仅在显式传入 `--pet-preview /path/to/image.png` 时读取指定图片。输出在 `.build/ui-design/`，渲染不启动生产引擎、不连接工牌。

工牌预览：在 `firmware/ai-passport/` 下按 `tools/render_pocket_ui.py --help` 指定匹配的 LVGL 源码目录。输出在 `build/pocket-ui/`；真实绘制与100次模式切换检查不替代硬件验收。

硬件产品照片来自 FoloToy，来源与 MIT 声明见 [资源说明](../../assets/passport/README.md)。
