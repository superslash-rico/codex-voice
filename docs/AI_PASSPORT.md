# AI Passport：从拿到硬件到连上 Codex

[返回项目首页](../README.md) · [下载本版全部文件](https://github.com/superslash-rico/codex-voice/releases/tag/v0.9.2-approval.1) · [固件源码](../firmware/ai-passport/)

这份指南面向第一次刷固件的用户。没有工牌时只安装 Mac 工具即可；本版的电脑端和工牌配件已整合为一个软件。

## 先确认硬件与电脑

| 项目 | 要求 |
| --- | --- |
| 工牌 | FoloToy **AI Passport**，ESP32-C3、8 MB Flash、无 PSRAM，原板载显示/麦克风/扬声器/三按键 |
| USB | 能传数据的线；只充电的线不能刷机 |
| Mac | 普通提醒及同步 macOS 13+；按住听写 macOS 26+ |
| 蓝牙 | Mac 蓝牙开启；工牌在附近；首次测试只开启一张工牌 |
| 电脑软件 | 本项目的 Codex 语音提醒；需要任务提醒时另安装支持 Hooks 的本地 Codex |
| 听写模型 | 简体中文 Apple 本机语音模型，当前不提供其他语言选择 |

<p align="center"><img src="../assets/passport/ai-passport-front.png" width="160" alt="本指南支持的 FoloToy AI Passport 实物"></p>

本固件不适用于所有 ESP32 开发板。引脚、编解码器和屏幕取向按 AI Passport 配置，其他型号不要套用。

## 路线 A：直接使用发布的固件

### 第一步：下载并校验

从同一 [Release](https://github.com/superslash-rico/codex-voice/releases/tag/v0.9.2-approval.1) 下载：

- `AI-Passport-Codex-0.3.0-pets-full.bin`：刷写用的完整镜像。
- `AI-Passport-Codex-0.3.0-pets.zip`：包含相同完整镜像、分段文件、分区信息、刷写说明及校验值的固件包。
- `SHA256SUMS.txt`：同版发行文件校验值。
- `CodexVoice-0.9.2-approval.1-universal.dmg`：Mac 工具。

在下载目录执行并对照 Release 中的值：

```sh
shasum -a 256 AI-Passport-Codex-0.3.0-pets-full.bin
```

**首次完整刷写会替换原有名片/演示程序，合并镜像也可能重置蓝牙配对和 NVS 设置。** 有需要保留的原应用数据时，先使用原应用支持的方式导出。无需把“读出原固件”作为前提，但本项目也不承诺自动恢复原固件。不要例行整片擦除，不要使用 `erase-flash`。

### 第二步：USB 刷写

推荐使用 Chrome 或 Edge 的 Web Serial（Safari 不支持该方式）。打开 [FoloToy 官方 Web 刷写器](https://ai-passport.folotoy.cn/tools/web-flasher/)，插入 USB 数据线，连接正确的 USB 串口，选完整镜像，确认**起始地址 `0x0`**，波特率可用 `460800`。按页面操作写入并等待校验完成，再重启工牌。

如果刷写器不可用，可用命令行。下面使用 esptool 5 的命令格式，在你自行创建的虚拟环境安装工具，不向系统 Python 写包：

```sh
python3 -m venv .venv-flash
source .venv-flash/bin/activate
python -m pip install 'esptool>=5,<6'
ls /dev/cu.usbmodem*
```

先确定刚插入的 AI Passport 对应端口。下面的 `/dev/cu.usbmodemXXXX` 是占位符，**替换为自己的端口**，不要照抄其他人的设备编号：

```sh
python -m esptool --chip esp32c3 --port /dev/cu.usbmodemXXXX flash-id
python -m esptool --chip esp32c3 --port /dev/cu.usbmodemXXXX --baud 460800 write-flash --flash-size 8MB 0x0 AI-Passport-Codex-0.3.0-pets-full.bin
```

`flash-id` 会建立连接并可能复位设备；刷写期间关闭串口监视器、退出会占用工牌的连接，不拔 USB。成功后重启工牌应显示 CODEX/屏保或等待连接界面。若当前应用镜像文件名不带 `full`，不能把它当完整镜像写到 `0x0`。

### 已有本项目固件，想保留设置？

先核对现有与新固件的分区表，不能把“分段写入”理解为永远保留数据。本版布局：

| 内容 | 起始地址 | 大小 |
| --- | --- | --- |
| Bootloader | `0x0` | 以发布文件为准 |
| 分区表 | `0x8000` | `0xC00` |
| NVS | `0x9000` | `0x6000` |
| PHY | `0xF000` | `0x1000` |
| factory 应用 | `0x10000` | `0x5F0000` |
| 宠物 A/B 资源区 | `0x600000` | `0x200000` |

在**已经核对兼容**后，固件 ZIP 内的三份程序文件可按 `flash_args` 指定偏移写入，不写 NVS、PHY 和宠物区。不要在未知布局上直接运行升级命令。0.3.0 引入 2 MiB 宠物资源区；从旧版或别的应用迁移，应预期可能需要重新配对和重新同步宠物。

## 路线 B：让 Codex 协助从源码构建

推荐把下面这段发给运行在你自己电脑上的 Codex。它需要你允许访问下载的项目目录；技能安装、环境安装、刷机等动作按实际情况确认，不能把文档本身当作授权。

```text
我是硬件新手，想把 FoloToy AI Passport 配置为 Codex 语音提醒配件。
我的硬件是 ESP32-C3、8 MB Flash、无 PSRAM 的 AI Passport。
请先阅读这个仓库的 README.md、docs/AI_PASSPORT.md，
以及 firmware/ai-passport/AGENTS.md 和 README.zh_CN.md。
先检查源码版本、ESP-IDF 5.5.3 环境、数据线和 USB 端口。
如缺少五项 passport-* 技能，请说明安装位置和作用，再按我的授权安装。
请使用 tools/validate.sh 构建和验证完整镜像，报告校验值和分区布局。
不要自动整片擦除，不要读取或上传我的登录凭据、聊天记录和配对码。
刷写前把设备、端口、固件版本和对设置的影响告诉我，等我同意再写入。
刷好后一步步指导我完成 Mac 工具安装、蓝牙配对、声音、宠物同步和听写测试。
```

手动构建也可以。克隆仓库后在固件目录操作；ESP-IDF 的安装说明见 [环境准备](../firmware/ai-passport/docs/development/engineering/environment-setup.md)：

```sh
git clone https://github.com/superslash-rico/codex-voice.git
cd codex-voice/firmware/ai-passport
# 先安装/激活 ESP-IDF v5.5.3，下面路径换成你自己的安装目录。
source /path/to/esp-idf-v5.5.3/export.sh
idf.py --version
./tools/validate.sh
```

构建需要 CMake、Ninja、对应编译器以及锁定的 Managed Components；首次下载需要联网。完整 gate 使用 `sdkconfig.defaults` 在隔离构建目录生成配置，不覆盖你本地 `sdkconfig`。产物为 `build/FoloToy-AI-Passport-full.bin`，并保留内容寻址归档及匹配的调试符号：

```sh
python3 tools/archive_firmware.py verify build/firmware/<完整镜像的SHA256>
```

`idf.py build` 是增量编译，不替代完整合并镜像验证。编译通过不等于工牌实测通过。构建命令不会自动刷机；确认后可按路线 A 刷入自己的完整镜像。

## 安装 Mac 工具并首次配对

1. 按 [项目首页](../README.md#下载安装先让电脑提醒跑起来) 安装 Mac 软件、连接 Codex 并审阅 Hooks。
2. 工牌开机，Mac 蓝牙开启；首页进入 **AI Passport**，打开 **启用 AI Passport**。首次允许 macOS 的蓝牙权限。
3. 工具会发现工牌；工牌显示六位数字时，在 **Mac 系统配对窗口** 输入当前数字并确认。无需把配对码告诉聊天助手。
4. 状态变成 **已连接** 后，任务和剩余额度开始同步。USB 可用于供电，日常通信使用 BLE，不需要 Wi-Fi。
5. 开启需要的声音：电脑播报和 AI Passport 播报互相独立。点 **试听 AI Passport**，按工牌确认键或电脑 **已接手** 结束。

一次只支持一台已配对主机；附近多张工牌时先只开启目标一张。后续登录自启和自动重连依赖 Mac 工具运行及系统允许蓝牙访问，不代表工牌脱离电脑独立运行。

### 重新配对 / 新固件通道未出现

如果系统仍使用旧的蓝牙服务缓存，可能已连接但图片通道不可用：

1. 先在 Mac 系统蓝牙中仅忽略这张工牌的旧配对。
2. 工牌短按任意键唤醒，长按 **上键** 打开“工牌操作”。
3. 默认“返回”时短按上键切到 **重新配对**，短按确认，再确认一次。
4. 回到 Mac 工具重新连接，并输入工牌新的六位码。

该操作清除工牌旧蓝牙绑定；昵称和宠物程序保留。不要忽略其他蓝牙设备。

## 屏幕与三个按键

| 当前界面 / 动作 | 结果 |
| --- | --- |
| 静置约 30 秒 | 进入宠物屏保 |
| 屏保时短按任意键 | 只唤醒，不误接手；无提醒显示用量，有提醒显示任务 |
| 额度页上/下键 | 切换可用额度周期 |
| 提醒页上/下键 | 切换待处理任务 |
| 提醒页短按确认 | 接手对应事项、停止提醒，在电脑定位聊天；不代替批准 |
| 长按确认 | 准备听写，开始音结束后讲话，松手处理 |
| 长按上键 | 工牌操作菜单，含重新配对等功能 |

任务、听写和同步比装饰动画优先；正在听写时普通提醒与宠物传输会让路。

## 自动同步宠物与昵称

**AI Passport → 屏保伙伴** 可查看进度、改昵称。昵称为 1–8 字，第一次安装默认 **Codex**；升级保留用户原来的名称，修改 Codex 的宠物名字不会覆盖这个独立昵称。完整刷机后、首次连接电脑前，工牌可能仍显示固件内置昵称；连接后会应用 Mac 中的 Codex 或你保存的名称。

在 Codex 的宠物设置中更换形象，先让图片在 Codex 中正常显示。Mac 工具后台转换并传输，完成校验后才切换工牌资源。首次需等待；同步时间随蓝牙质量和正在进行的任务变化，不承诺固定几秒内完成。

当前读取本机选中宠物 ID、安装包内置资源、本地自定义资源及选中云端宠物的本地图片缓存。资源暂不可读会显示等待原因并保留旧形象，不会把未传完的数据直接显示出来。该能力是本工具的适配，并非 OpenAI 官方硬件同步接口。

## 按住讲话，文字进入电脑

1. 确认 **macOS 26+**。在系统启用简体中文听写/相应本机语音资源；模型可用性以本机为准，首次安装可能联网下载。
2. 在 **AI Passport → 按住听写 → 设置 → 检查本机中文模型** 中确认“已就绪”。
3. 点击 **开启辅助功能权限**，在系统“设备控制和数据访问”（部分系统称“辅助功能”）中为 **Codex 语音提醒** 开启权限。密码或触控 ID 只在系统窗口中完成。
4. 收起工具，手动点击 Codex 或其他应用的普通输入框，让光标出现。
5. 长按工牌确认键，等**开始单音结束**再讲话，讲话时一直按住。
6. 松开，屏幕显示处理状态；**上扬双音**表示文字已写入原输入框，不代表消息已发出。
7. 检查文字，自己点击发送。

一次处理一段，最长约 30 秒。识别只用 Mac 本地 Apple SpeechAnalyzer/SpeechTranscriber，不走云端转写，不保存录音文件。工牌麦克风通过 BLE 发音频，不是普通蓝牙耳机输入设备。

未识别、传输不完整、权限不足或目标焦点改变时，不响普通成功双音。已识别但未能确认落字的文字保留在**当前应用进程内**，可从 **查看保留的听写文字** 手动复制；成功时不自动弹出保留面板。退出前复制需要保留的文字。某些应用不暴露可编辑输入框、安全输入框或特殊编辑器可能不兼容。

## 排错与自行验收

| 情况 | 操作 |
| --- | --- |
| Mac 没串口 | 换数据线/USB 口；对比插拔前后的 `/dev/cu.usbmodem*`；退出占用串口的软件 |
| 刷写连接超时 | 核对 ESP32-C3、端口和8 MB；按官方板卡指南进入下载模式；不要凭猜测短接引脚 |
| 已连接但不播报 | AI Passport 播报、总开关、暂停、免打扰、工牌音量和试听是否开启 |
| 宠物不变 | Codex 中图像已下载；设置页同步状态；听写/审批优先时稍等；旧服务缓存按上文重新配对 |
| 语音有识别但不落字 | 检查焦点和输入权限；临时签名升级后重新添加本应用授权；先用普通文稿输入框测试 |
| 没有开始音 | 看工牌“准备中/失败”文字；模型、权限或连接不满足时不会伪装成可以讲话 |
| 没有完成音 | 看是否识别失败、目标改变或文字待保留；电脑收到音频不等于落字成功 |

完成后自己逐项确认：新界面可读 → 配对连接 → 电脑/工牌声音可独立控制 → 实际任务接手 → 用量可读 → 更换 Codex 宠物后屏保自动变更 → 昵称正确 → 听写落字、不自动发送、两个音效正常 → 重启应用后设置和重连恢复。

本次发行的实测与未验证范围见 [验证记录](VALIDATION.md)。续航、蓝牙距离、长时间传输与其他 Mac 的兼容性需要对应硬件测试。

## 参考

- [FoloToy AI Passport 项目](https://github.com/FoloToy/ai-passport)
- [Espressif：esptool 写入命令](https://docs.espressif.com/projects/esptool/en/latest/esp32c3/esptool/basic-commands.html)
- [本版固件布局与存储策略](../firmware/ai-passport/docs/development/engineering/firmware-layout.md)
- [OpenAI Docs：Hooks 与信任](https://learn.chatgpt.com/docs/hooks)
