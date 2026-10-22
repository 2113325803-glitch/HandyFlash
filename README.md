# HandyFlash

iPad 分屏手写闪卡采集器（MVP）—— Apple Pencil 手写 → 停笔自动收卡 → 按日期复习。

![platform](https://img.shields.io/badge/iPadOS-16.0%2B-blue)
![swift](https://img.shields.io/badge/Swift-5.7%2B-orange)
![dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)
![playgrounds](https://img.shields.io/badge/Swift_Playgrounds-single--file-success)

> **当前进度：阶段 5 / 6（卡片页重构）**
> 已完成：SwiftUI App 骨架、PencilKit 手写画布、上下分区模板、分屏自适应、停笔检测与环形倒计时、自动收卡、收卡动画、撤销上一张、本地持久化（Documents）、标签页。
> 本次新增：**笔刷颜色 / 粗细工具栏、随机激励语、按日期分组、沉浸式左右翻卡 + 点击翻面（3D）、选择性删除（左滑单张 / 多选批量）**。
> 待实现：设置页（收卡延时、自动收卡开关）、阶段 6 边界审查。
>
> ✅ 收到的卡片写入 `Documents/HandyFlash/`，**关闭并重新打开 App 后仍然存在**。
> ✅ 采集页与卡片页共用同一份数据：收一张卡，对应的日期集合立刻 +1，标签角标同步。

---

## 目录

| 章节 | 内容 |
| --- | --- |
| [一、用 Xcode 运行](#一重要当前目录不是完整-xcode-工程) | 没有 `.xcodeproj` 时如何把源码接进工程 |
| [二、用 iPad + Swift Playgrounds 运行](#二用-ipad--swift-playgrounds-运行没有-mac-时用这个) | **推荐方式**：不需要 Mac |
| [三、验收清单](#三验收清单) | 各阶段功能项与自检步骤 |
| [四、目录结构](#四目录结构) | 两个源码树的组织方式 |
| [五、分阶段路线图](#五分阶段路线图) | 进度、技术约束 |

---

## 一、重要：当前目录不是完整 Xcode 工程

本仓库目前**只有 Swift 源码**，没有 `.xcodeproj`。请在 macOS 的 Xcode 中按下面步骤创建工程。

> 没有 Mac？请直接跳到 **第二节：用 iPad + Swift Playgrounds 运行**。

### 1. 新建工程

1. Xcode → **File → New → Project…**
2. 选择 **iOS → App**。
3. Product Name 填 `HandyFlash`。
4. Interface 选 **SwiftUI**，Language 选 **Swift**，Storage 选 **None**。
5. 取消勾选 **Include Tests**（MVP 不需要）。
6. 保存到一个临时目录或桌面。
   **不要直接保存到本仓库根目录**，因为 Xcode 会生成同名的 `HandyFlash/` 源码目录，与仓库现有目录冲突。

### 2. 把本仓库源码加入工程

1. 在 Xcode 工程导航器中删除模板自带的 `ContentView.swift`（Move to Trash）。
2. 删除模板自带的 `HandyFlashApp.swift`（Move to Trash），避免和本项目的 `@main` 入口重复。
3. 在 Finder 中打开本仓库的 `HandyFlash/` 目录。
4. 把 `App`、`Features`、`Models`、`Stores`、`Utilities` 五个文件夹整体拖进 Xcode 工程导航器：
   - Xcode 15 及更早：选择 **Create groups**，Target 勾选 `HandyFlash`。
   - Xcode 16+：默认使用文件夹同步，拖入后文件会自动加入 target；确认 Target Membership 勾选 `HandyFlash` 即可。
   - 如果 Xcode 提示 `HandyFlashApp.swift` 已存在，保留本仓库的版本，不要重复添加。
5. 确认工程中只有一个 `@main`（位于 `App/HandyFlashApp.swift`）。
6. 工程建好后，可以把 `.xcodeproj` 移回本仓库根目录，保持 `HandyFlash.xcodeproj` 与源码目录 `HandyFlash/` 同级即可正常编译。

### 3. 必需的 Target 设置

| 设置项 | 值 |
| --- | --- |
| Minimum Deployments（iOS / iPadOS） | **16.0**（项目使用了 `NavigationStack` 等 iOS 16 API） |
| Supported Destinations | iPad（保留 iPhone 也能编译，但界面按 iPad 优先设计） |
| Deployment Info → iPad Orientations | 建议四个方向全部勾选 |
| Requires full screen | **必须关闭**（不要设置 `UIRequiresFullScreen = YES`），否则无法分屏 / Slide Over |
| Capabilities | 不需要任何 Capability |
| Info.plist | 不需要额外键值；PencilKit 不需要隐私权限 |

### 4. 编译运行

- 选择 iPad 模拟器（如 **iPad Pro 11-inch**，iPadOS 16+），`Cmd + B` 编译，`Cmd + R` 运行。
- 模拟器中用鼠标拖拽即可书写；真机上可用 Apple Pencil 或手指。
- 分屏验证：iPad 上从底部上滑打开 Dock，长按另一个 app（如“备忘录”）拖到屏幕边缘进入 Split View，再把 HandyFlash 放进另一侧。窄宽度下画布应完整、无横向裁切。

> 本仓库在 Windows 环境生成，无法调用 `xcodebuild` 做真实编译。代码按 iPadOS 16 API 编写；如遇编译错误，请把 Xcode 报错发给我。

---

## 二、用 iPad + Swift Playgrounds 运行（没有 Mac 时用这个）

> **推荐方式。** Swift Playgrounds 的 **App** 项目会自动生成工程配置，不需要（也无法）手写 `.xcodeproj` 或 `Info.plist`。新建一个 App 项目后，把 `SwiftPlaygrounds/` 目录里的 17 个 `.swift` 文件逐个粘贴进去即可。

### 1. 新建 App 项目

1. 打开 **Swift Playgrounds**（App Store 免费；需要 iPadOS 16+，建议更新到最新版）。
2. 在“我的 Playground”界面点 **+** → 选择 **App**（不是 Playground、不是 Book）。
3. 名称填 `HandyFlash`，图标随意 → **创建 / Create**。
4. 项目会自动生成 `App.swift` 和 `ContentView.swift`（部分版本还有 `Assets`），这两份就是后面要整体替换的文件。

### 2. 文件怎么放

| 项目里的文件 | 来源 |
| --- | --- |
| `App.swift` | 用 `SwiftPlaygrounds/App.swift` 全文替换 |
| `ContentView.swift` | 用 `SwiftPlaygrounds/ContentView.swift` 全文替换 |
| 其余 15 个文件 | 在项目里**新建**同名文件，再粘贴对应代码 |

其余 15 个文件（全部放在项目根目录，与 `App.swift` 平级）：

```text
Flashcard.swift
FlashcardStore.swift
DrawingRenderer.swift
NavigationContainer.swift
PencilCanvasView.swift
CanvasTemplateView.swift
CountdownRingView.swift
CaptureFlightOverlay.swift
InkSettings.swift
CaptureController.swift
CaptureView.swift
CardDayGroup.swift
CardsView.swift
DayCollectionView.swift
FlashcardPageView.swift
```

**更省事的做法（推荐）：单文件版**

如果不想建 15 个文件，可以直接用 `SwiftPlaygrounds/SingleFile/ContentView.swift`（约 2300 行，所有类型都在一个文件里）：

- 把项目里的 `ContentView.swift` **整份替换**成它；
- `App.swift` 保持模板原样（它调用 `ContentView()`）；
- 不需要再新建任何文件。

该文件末尾有一段**注释掉**的 `@main`，默认不要启用（项目里已经有 `App.swift` 的 `@main`，启用会出现两个入口）。

**新建文件的方法**：回到文件列表（项目名旁边的文件图标 / 返回箭头），点 **+** → **New File**（新建文件），输入文件名（如 `Flashcard`，有的版本要求写 `Flashcard.swift`），确定后把代码粘贴进去。Swift Playgrounds 会把同一项目里所有 `.swift` 当作一个模块编译，文件顺序不影响结果。

**注意事项**

- **不要建子文件夹**：各版本对文件夹的支持不一致，所有文件平铺在项目根目录最稳。
- 原来的 `RootView.swift` **不需要**放进 Playgrounds，它的职责已由 `ContentView.swift` 承担。
- 不需要 `Assets`、不需要改 `Package.swift`、不需要任何 `Info.plist` 键（PencilKit 不需要隐私权限）。
- 粘贴 `ContentView.swift` 时保留第一行 `import SwiftUI`。

### 3. 运行

1. 点右上角 **Run（▶）**，首次编译需要几十秒。
2. 运行后 App 会占满预览窗口，角落里有停止 / 返回按钮。
3. 用 Apple Pencil 或手指在画布上书写；停笔约 3 秒后自动收卡。

### 4. Swift Playgrounds 的已知限制

| 限制 | 说明 |
| --- | --- |
| 分屏验证 | Playgrounds 里运行的 App 预览通常占满预览窗口，**无法像正式安装的 App 那样与其他 App 并排**。可用 **Stage Manager** 缩放 Playgrounds 窗口、或旋转屏幕来验证窄宽度布局；真正的分屏验收需要以后用 Xcode 装到 iPad。 |
| 部署目标 | 模板的 iOS 部署目标由 Swift Playgrounds 决定。`ContentView.swift` 已对 iOS 16 以下做了 `NavigationView` 回退，所以模板目标偏低也能编译。若仍报 “X is only available in iOS 16.0”，升级 iPadOS 后重新新建项目即可。 |
| 数据持久化 | 阶段 3 起卡片写入 App 沙盒的 `Documents/HandyFlash/`。预览沙盒重新 Run 一般保留，但**重新编译 / 删除项目可能清空**，这是预览环境的限制，不是 App 逻辑问题。 |
| `Package.swift` | 由 Playgrounds 自动生成并管理，界面里通常不可见，也不需要修改。 |

---

## 三、验收清单

### 阶段 1（已完成）

- [ ] `Cmd + B` 编译通过，无第三方依赖。
- [ ] 启动后看到一张白色画布，上半区显示“单词 / WORD”，下半区显示“翻译 / TRANSLATION”，中间有浅色虚线。
- [ ] 手指可以在画布上书写；真机上 Apple Pencil 也能书写。
- [ ] 笔迹显示在模板之上，不会被模板遮挡。
- [ ] 在 Split View / Slide Over 的窄宽度下，画布仍然完整，标签不溢出。
- [ ] 旋转屏幕、拖动分屏比例后，画布自适应，笔迹不会漂移。
- [ ] 右上角垃圾桶按钮弹出确认框；确认后画布清空。

### 阶段 2（已完成，已验收）

> 2026-10-21 已在 iPad 上验收通过。

- [ ] 写完后停笔，画布底部中央出现环形倒计时，约 3 秒后自动收卡并清空画布。
- [ ] 倒计时期间重新落笔，倒计时立即消失；再次停笔后重新计时。
- [ ] 空画布停笔不会出现倒计时，也不会产生空卡片。
- [ ] 收卡时能看到卡片缩小、滑向右上角的轻量动画。
- [ ] 左上角“找回上一张”能把刚收的卡片放回画布；画布已有内容时会先弹确认。
- [ ] 右上角“立即收卡”可以手动收卡；没有笔迹时按钮为禁用状态。
- [ ] 顶部提示条右侧显示张数，N 随收卡 / 找回正确变化（阶段 3 起文案为“已存 N 张”）。
- [ ] 分屏窄宽度下工具栏按钮不重叠，倒计时环只出现在画布底部，不遮挡书写。
- [x] 注意：本阶段卡片只在内存中，**重启 App 后会清空**（阶段 3 已解决：改为写入 `Documents`）。

### 阶段 2 实现要点

| 需求 | 实现位置 |
| --- | --- |
| 停笔检测 | `CaptureController` 实现 `PKCanvasViewDelegate`：`canvasViewDidBeginUsingTool` 取消倒计时，`canvasViewDidEndUsingTool` 开始倒计时 |
| 倒计时刷新 | 主 RunLoop `.common` 模式下的 `Timer`，30fps 更新 `countdownProgress`，拖动 / 滚动时也不暂停 |
| 空画布保护 | 开始计时、计时中、收卡前都检查 `drawing.strokes.isEmpty`；`Flashcard` 的失败初始化器再兜一层 |
| 收卡 | `PKDrawing.dataRepresentation()` + `DrawingRenderer.thumbnailImage` + `Date()`，随后清空画布 |
| 撤销上一张 | 把最近一张的 `PKDrawing` 放回画布并从列表移除；画布非空时由视图弹确认 |
| 收卡动画 | `PassthroughSubject<UIImage, Never>` 通知视图，`CaptureFlightOverlay` 用 `withAnimation` 缩小 + 位移 + 淡出 |
| 后台保护 | 收到 `willResignActive` 时取消倒计时，避免回到前台时“突然”收卡 |

### 阶段 3（已完成，已验收）

> 2026-10-21 已在 iPad 上验收通过。

- [ ] 连续收几张卡，顶部提示条显示“已存 N 张”。
- [ ] 彻底关闭 App（上滑划掉）后重新打开，N 仍然不变——**卡片已经写到磁盘**。
- [ ] 重启后点“找回上一张”，画布上出现关闭前最后收的那张笔迹（说明笔迹是从文件读回来的）。
- [ ] 找回后 N 减 1；再次关闭并重开，卡片数不会再变回来（索引同步更新了）。
- [ ] 在 Playgrounds 里重新 Run，卡片仍在；删除项目 / 重装后清空属于预览环境限制。
- [ ] 故意把画布写满再收卡，重复 10 次以上，App 不卡顿、张数正确。
- [ ] 存储出错时会弹“存储出错了”，点“好”后可以继续书写，App 不闪退。

### 阶段 3 实现要点

| 需求 | 实现位置 |
| --- | --- |
| 落盘位置 | `FlashcardStore`：`Documents/HandyFlash/index.json` + `Drawings/<uuid>.pkdrawing` + `Thumbnails/<uuid>.png` |
| 原子写入 | 所有文件都用 `Data.write(to:options:.atomic)`（先写临时文件再替换）；**索引最后写**，不会出现“索引里有、文件没了” |
| 启动加载 | `init` 里同步读索引 → 逐张读笔迹与缩略图 → `PKDrawing(data:)` 校验，解析失败的卡片跳过 |
| 收卡 | `CaptureController.captureNow()` 调 `store.add(card)`：内存立即更新，文件在串行 I/O 队列后台写 |
| 找回上一张 | `store.remove(id:)`：先写索引再删两个文件；笔迹放回画布 |
| 界面张数 | 提示条改为“已存 N 张”，直接读 `store.count`，与磁盘一致 |
| 错误处理 | 索引损坏时改名保留为 `index-corrupt-<时间>.json` 并以空库启动；写盘失败由 `CaptureView` 弹窗提示 |
| 实例共享 | `RootView` / `ContentView` 用 `@StateObject` 持有 `FlashcardStore`，通过 `CaptureView(store:)` 注入，卡片页复用同一实例 |

### 阶段 4 + 5（当前，待验收）

**采集页**

- [ ] 画布上方出现笔刷条：黑 / 红 / 蓝三个圆点，细 / 中 / 粗三个圆点；选中的那一个有一圈强调色。
- [ ] 选红色 + 粗，写出来是红色粗笔；切回黑色 + 细，下一笔立刻变化（不用重启）。
- [ ] 换颜色 / 粗细不会清空已写内容；分屏窄宽度下笔刷条不换行、不遮挡画布。

**卡片页**

- [ ] 顶部每次进入都换一句激励语（切标签回来、从集合返回都会变）。
- [ ] 一天收好几张，卡片页只看到一行「10月21日 · N 张卡片」，封面是当天最新那张。
- [ ] 点这一行进入集合：整页翻卡，左右滑动切换、没有页码点；底部显示「3 / 8」。
- [ ] 轻点卡片 → 3D 翻到背面，显示完整一页（单词 + 翻译）；再点翻回正面。
- [ ] 正面只露出上半区（单词），下半区是白纸 + “轻点翻面看翻译”。
- [ ] 翻到下一张时是正面朝上的（不继承上一张的翻面状态）。
- [ ] 右上角「选择」→ 勾选多张 → 垃圾桶 → 确认 → 这几张一起消失，其余还在。
- [ ] 选择模式下左滑某一行 → 删除，只删这一张。
- [ ] 卡片页左滑某一天 → 删除 → 确认 → 这天的卡片全没了，其它日期不受影响。
- [ ] 界面上**没有**“一次删光全部”的按钮。
- [ ] 删到当天最后一张后自动退回卡片页，标签角标同步。
- [ ] 删除后彻底关闭 App 再打开，删掉的卡片不会“复活”。
- [ ] 分屏窄宽度下，集合行的日期 / 张数不被截断，翻卡区仍然完整。

### 阶段 4 + 5 实现要点

| 需求 | 实现位置 |
| --- | --- |
| 标签结构 | `RootView` / `ContentView`：`TabView`（采集 / 卡片），每个标签各自包一层 `NavigationContainer`（iOS 16+ `NavigationStack`，更老回退 `NavigationView`） |
| 数据共享 | 根视图 `@StateObject var store` 通过 `CaptureView(store:)`、`CardsView(store:)` 注入同一实例；`.badge(store.count)` 跟着同步 |
| 笔刷工具栏 | `InkSettings.swift` 定义 `InkColor`（黑 / 红 / 蓝）与 `InkWidth`（细 2pt / 中 4.5pt / 粗 8pt）；`CaptureController.applyTool()` 直接写 `canvasView.tool = PKInkingTool(.pen, …)`，`CaptureView.brushBar` 只负责选值 |
| 工具由谁设置 | `PencilCanvasView.configure` 不再写死颜色粗细（否则会覆盖用户刚选的笔刷），只留兜底；`updateUIView` 仍然什么都不做，避免打断正在写的笔迹 |
| 随机激励语 | `MotivationPhrases.all`（16 句）+ `CardsView` 顶部条，`.onAppear` 每次重抽 |
| 按日期分组 | `FlashcardStore.dayGroups`：按 `Calendar.startOfDay` 分桶，沿用索引里“最新在前”的顺序；`cards(on:)` 供集合页读取 |
| 集合行 | `CardDayRow`：58×58 封面（当天最新缩略图）+ `M月d日` + 「N 张卡片」 |
| 沉浸式翻卡 | `DayCollectionView`：`TabView(selection:)` + `PageTabViewStyle(indexDisplayMode: .never)`，卡片从 store 实时读取 |
| 点击翻面 | `FlashcardPageView`：两段式 3D 翻转（0°→90° 换面→-90°→0°），任何时刻只有一面朝前，不会看到镜像字 |
| 正面遮挡 | 正面按 `pageSize` 等比缩放后 `.clipped()` 到上半页，下半页盖白纸 + 提示；背面显示整页（`DrawingRenderer.pageImage(scale: 2)`） |
| 左滑删除一天 | `CardsView` 的 `.swipeActions` → 二次确认 → `store.remove(ids:)` |
| 多选删除 | `DayCollectionView.isSelecting` + `selection: Set<UUID>`；工具栏垃圾桶 → 确认 → `store.remove(ids: Array(selection))` |
| 批量删除顺序 | `FlashcardStore.remove(ids:)`：内存先移除 → 重写索引 → 再删笔迹与缩略图（失败只留下孤儿文件，不会出现坏引用） |
| 删光后的收尾 | `onChange(of: cards.count)`：为 0 时 `dismiss()`；变小时把当前页码夹回合法范围 |

---

## 四、目录结构

当前（阶段 5）：

```text
HandyFlash/                          # 仓库根目录
├── README.md                        # 项目说明（本文件）
├── .gitignore / .gitattributes      # 忽略规则 / 统一 LF 换行
├── HandyFlash/                      # Xcode 版本源码（分文件夹）
│   ├── App/
│   │   ├── HandyFlashApp.swift      # @main 入口
│   │   └── RootView.swift           # 根视图：TabView（采集 / 卡片）
│   ├── Features/
│   │   ├── Capture/
│   │   │   ├── CaptureView.swift           # 采集页布局、笔刷条、倒计时浮层、收卡动画触发
│   │   │   ├── CaptureController.swift     # 停笔检测、倒计时、自动收卡、撤销、笔刷设置
│   │   │   ├── InkSettings.swift           # 笔迹颜色（黑 / 红 / 蓝）与粗细（细 / 中 / 粗）
│   │   │   ├── PencilCanvasView.swift      # PKCanvasView 包装 + 固定尺寸画布
│   │   │   ├── CanvasTemplateView.swift    # 单词 / 翻译分区模板
│   │   │   ├── CountdownRingView.swift     # 环形倒计时
│   │   │   └── CaptureFlightOverlay.swift  # “卡片滑入卡片栈”的动画
│   │   └── Cards/
│   │       ├── CardsView.swift             # 按日期分组的集合列表 + 随机激励语 + 左滑删一天
│   │       ├── CardDayGroup.swift          # 日期分组、按天取卡、激励语、日期格式
│   │       ├── DayCollectionView.swift     # 沉浸式翻卡 + 多选删除
│   │       └── FlashcardPageView.swift     # 单张卡（3D 翻面、正面遮挡下半页）
│   ├── Models/
│   │   └── Flashcard.swift          # 卡片数据（纯数据，不关心文件路径）
│   ├── Stores/
│   │   └── FlashcardStore.swift     # Documents 持久化：索引 + 笔迹 + 缩略图
│   └── Utilities/
│       ├── DrawingRenderer.swift    # PKDrawing → 缩略图 / 整页图片
│       └── NavigationContainer.swift # NavigationStack / NavigationView 兼容包装
└── SwiftPlaygrounds/                # iPad Swift Playgrounds App 项目用的扁平源码
    ├── App.swift                    # 直接替换模板的 App.swift
    ├── ContentView.swift            # 直接替换模板的 ContentView.swift（TabView + iOS 16 回退）
    ├── Flashcard.swift
    ├── FlashcardStore.swift
    ├── DrawingRenderer.swift
    ├── NavigationContainer.swift
    ├── PencilCanvasView.swift
    ├── CanvasTemplateView.swift
    ├── CountdownRingView.swift
    ├── CaptureFlightOverlay.swift
    ├── InkSettings.swift
    ├── CaptureController.swift
    ├── CaptureView.swift
    ├── CardDayGroup.swift
    ├── CardsView.swift
    ├── DayCollectionView.swift
    ├── FlashcardPageView.swift
    └── SingleFile/
        └── ContentView.swift        # 单文件版：所有类型合并，直接覆盖 ContentView.swift（阶段 5：约 2300 行）
```

> `HandyFlash/` 与 `SwiftPlaygrounds/` 的功能代码相同，只有两处差异：
> 1. Swift Playgrounds 版没有 `#Preview` / `PreviewProvider` 预览代码；
> 2. 入口用 `ContentView.swift`（带 iOS 16 以下回退）代替 `RootView.swift`。
> 后续阶段会同步更新两份。

后续阶段规划：

```text
HandyFlash/
├── App/                  # 入口、RootView / TabView
├── Features/
│   ├── Capture/          # 画布、倒计时、收卡反馈、笔刷、CaptureController（已完成）
│   ├── Cards/            # 日期分组、沉浸式翻卡、翻面、选择性删除（已完成）
│   └── Settings/         # 设置页（阶段 6）
├── Models/               # Flashcard、AppSettings
├── Stores/               # FlashcardStore（FileManager）
└── Utilities/            # 缩略图渲染等
```

---

## 五、分阶段路线图

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 1 | App 骨架、PencilKit 画布、上下分区模板、分屏适配 | ✅ 已完成 |
| 2 | 停笔检测、环形倒计时、自动收卡、清空、撤销上一张 | ✅ 已完成 |
| 3 | Flashcard 模型、FileManager 持久化、缩略图 | ✅ 已完成 |
| 4 | 卡片栈列表、删除、单卡查看 | ✅ 已完成 |
| 5 | 翻面复习、笔刷颜色 / 粗细、随机激励语、按日期分组、选择性删除 | 🚧 进行中（设置页待做） |
| 6 | 设置页（1～10 秒、自动收卡开关、说明）、边界情况审查与整体验证 | ⏳ 待开始 |

### 技术约束（全程遵守）

- SwiftUI + PencilKit + Combine/Foundation，**零第三方依赖**。
- 最低 iPadOS 16.0。
- 不使用数据库；图标数据写入 `Documents` 下的文件。
- MVP 不做 OCR、云同步、跨 app 扩展、Anki 集成、账号系统。
