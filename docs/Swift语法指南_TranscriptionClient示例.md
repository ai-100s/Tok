# Swift 语法入门：以 `TranscriptionClient.swift` 为例

> 本文档面向 **Swift 初学者**，通过分析 `Hex/Clients/TranscriptionClient.swift` 源码中的片段，讲解常见语法与并发特性。阅读完后，你将理解 *struct*、*actor*、*extension*、*guard*、以及 `@DependencyClient` 等关键概念的含义与使用场景。

---

## 0. 文件上下文
`TranscriptionClient.swift` 是 Hex 项目中的核心文件，负责音频转录功能的统一封装。它囊括了大量 Swift 语法与 Concurrency 特性，非常适合作为学习材料。


## 1. `struct` —— 值类型数据模型
在 Swift 中，`struct`（结构体）是一种 **值类型**：实例在传递或赋值时会被 **复制**，保证数据不可变性与线程安全。这使其非常适合用来描述纯数据。

**示例：定义流式转录更新的数据结构**
```15:22:Hex/Clients/TranscriptionClient.swift
struct StreamTranscriptionUpdate: Equatable {
  let confirmedSegments: [TranscriptionSegment]
  let unconfirmedSegments: [TranscriptionSegment]
  let currentText: String
  let isComplete: Bool
}
```
解释：
- `Equatable` 遵循协议，自动合成 `==`，便于比较两次更新是否相等。
- 所有属性用 `let` 声明（只读），强调不可变性。

> 与 `class` 的区别：`class` 是 **引用类型**，在传递时共享同一实例，更适合需要可变状态且想在多个地方共享的场景。


## 2. `@DependencyClient` —— 依赖注入的宏
```25:43:Hex/Clients/TranscriptionClient.swift
@DependencyClient
struct TranscriptionClient {
  var transcribe: @Sendable (...) async throws -> String
  ...
}
```
- `@DependencyClient` 来源于 *Swift Composable Architecture (TCA)* 的 *Dependencies* 库，是一种 **宏**（Macro）。
- 它会 **自动生成** 配套的 `DependencyKey`、`DependencyValues` 扩展等样板代码，从而让 `TranscriptionClient` 能通过 `DependencyValues` 全局注入 / 替换（例如在测试中注入模拟实现）。
- `@Sendable` 修饰闭包，表明其可安全跨并发域调用。
- `async throws` 表示函数是 **异步** 且可能抛出错误。

> 宏在编译期展开，类似其他语言的注解（Annotation）或代码生成器，能显著减少样板代码。


## 3. `extension` —— 给已有类型加料
Swift 的 `extension` 允许在 **不修改源码** 的前提下，为一个类型增加新的方法、计算属性、遵循协议等。

```46:60:Hex/Clients/TranscriptionClient.swift
extension TranscriptionClient: DependencyKey {
  static var liveValue: Self {
    let live = TranscriptionClientLive()
    return Self(
      transcribe: { try await live.transcribe(url: $0, model: $1, options: $2, settings: $3, progressCallback: $4) },
      ... // 其它字段省略
    )
  }
}
```
解释：
- 这里给 `TranscriptionClient` **添加了对 `DependencyKey` 协议的实现**。
- `liveValue` 提供了"真实（生产环境）"的默认实现，供依赖注入容器调用。
- 通过 `extension`，我们避免在原始 `struct` 声明中塞入协议实现，使代码更加模块化、清晰。


## 4. `actor` —— 并发时代的同步利器
Swift **Concurrency** 提供 `actor` 关键字来解决并发下的数据竞争问题。`actor` 保证：
1. 内部状态只能由 **一个线程** 同时访问；
2. 外部调用默认是 **异步** 的，需要 `await`。

```102:109:Hex/Clients/TranscriptionClient.swift
actor TranscriptionClientLive {
  // MARK: - Stored Properties
  private var whisperKit: WhisperKit?
  private var currentModelName: String?
  ...
}
```
为什么要用 `actor`？
- `TranscriptionClientLive` 内部同时涉及 **磁盘 I/O、网络下载、音频流处理** 等并发任务。
- 通过 `actor`，我们能保证例如 `whisperKit` 或 `currentModelName` 在多线程下不会产生竞态条件。

**调用形式**
```swift
let client = await TranscriptionClientLive()
try await client.downloadAndLoadModel(variant: "tiny", progressCallback: { ... })
```
> 注意：访问 `actor` 成员需要 `await`，因为编译器会在内部插入异步调度。


## 5. `guard` —— 提前退出的保护语句
`guard` 用于在 **条件不满足** 时立即退出当前作用域（`return` / `throw` / `continue` / `break`）。它让"happy path"左对齐，提高可读性。

```213:219:Hex/Clients/TranscriptionClient.swift
guard fileManager.fileExists(atPath: modelFolderPath) else {
  // 若目录不存在，提前返回 false
  return false
}
```
解析：
- `guard` 后跟布尔表达式，**仅当条件为 `false` 时** 执行 `else` 块。
- 在 `else` 中必须退出当前作用域，否则编译器会报错。
- 可与 `let`/`var` 结合进行可选绑定：
  ```swift
  guard let url = URL(string: string) else { return }
  ```

> 使用 `guard` 能有效减少多层嵌套的 `if`，让主流程更加直观。


## 6. 其它相关语法一览
| 语法 | 作用 | TranscriptionClient 中的示例 |
| ---- | ---- | ---- |
| `async/await` | 定义/调用异步函数 | `async throws -> String`、`try await live.transcribe(...)` |
| `throws` / `try` | 错误传播 & 捕获 | `try await WhisperKit.fetchAvailableModels()` |
| `private` / `public` 等访问控制 | 控制可见性 | `private var whisperKit: WhisperKit?` |
| Trailing Closure | 闭包作为最后一个参数可省略参数名 | `downloadModelIfNeeded(variant:) { progress in ... }` |
| `Progress` | Foundation 中的进度追踪类 | `let overallProgress = Progress(totalUnitCount: 100)` |
| `lazy var` | 首次访问时才初始化 | `private lazy var modelsBaseFolder: URL = { ... }()` |
| `Task { ... }` | 创建新的异步任务 | `streamTask = Task { [weak self] in ... }` |


## 7. 小结
通过上文，你应已掌握：
- **struct 与 class 的根本区别**；
- 如何通过 **`@DependencyClient` + `extension`** 实现依赖注入；
- `actor` 解决并发安全问题的原理与用法；
- 用 `guard` 让代码更加平铺直叙；
- 以及 Swift Concurrency 中的一些常用关键字。

建议下一步：
1. 在 Xcode 中把断点打在上述代码处，单步调试体验 `actor` 的串行特性；
2. 实践：尝试为 `TranscriptionClient` 写一个 **Mock 实现**，并在单元测试里通过 `withDependencies` 注入；
3. 阅读官方文档《Swift Concurrency》章节，深化对 *actor isolation* 与 *Sendable* 的理解。

> 祝学习顺利，玩转 Swift 🚀 