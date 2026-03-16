# ClaudeUsageBar

macOS 菜单栏应用，用于监控 Claude.ai 用量。支持双账号同时监控。

## 构建

```bash
cd app && ./build.sh
```

构建产物：`app/build/ClaudeUsageBar.app`（Universal Binary: arm64 + x86_64）

## 架构

单文件应用：`app/ClaudeUsageBar.swift`

### 核心类

- **AppDelegate** — 菜单栏图标、弹窗管理、全局快捷键 (⌘U)
- **AccountData** — 单个账号的数据模型（ObservableObject），持有 session/weekly/sonnet 用量
- **UsageManager** — 全局数据管理器，持有 account1 + account2，负责网络请求和通知
- **AccountUsageView** — 单账号用量显示子视图（进度条 + 重置时间）
- **CookieInputSection** — 单账号 Cookie 输入子视图
- **UsageView** — 主弹窗 SwiftUI 视图，组合两个账号的用量和设置

### 框架

- SwiftUI — 弹窗 UI
- AppKit — NSStatusItem、NSPopover、NSUserNotification
- Carbon — 全局快捷键注册
- Combine — objectWillChange 转发（嵌套 ObservableObject）

### 数据存储（UserDefaults）

| Key | 说明 |
|-----|------|
| `claude_session_cookie_1` / `_2` | 账号 1/2 的完整 Cookie |
| `last_notified_threshold_1` / `_2` | 各账号上次通知的阈值 |
| `notifications_enabled` | 全局通知开关 |
| `open_at_login` | 登录时启动 |
| `shortcut_enabled` | ⌘U 快捷键开关 |

旧版单账号 key `claude_session_cookie` 和 `last_notified_threshold` 会在首次启动时自动迁移到 `_1`。

### API 端点

- `https://claude.ai/api/bootstrap` — 获取 organizationId
- `https://claude.ai/api/organizations/{orgId}/usage` — 获取用量数据

### 响应格式

```json
{
  "five_hour": { "utilization": 45.5, "resets_at": "..." },
  "seven_day": { "utilization": 62.3, "resets_at": "..." },
  "seven_day_sonnet": { "utilization": 38.1, "resets_at": "..." }
}
```

`seven_day_sonnet` 仅 Pro 套餐存在，用于自动检测 Pro/Free。

## 约定

- 所有代码集中在单文件 `app/ClaudeUsageBar.swift`
- 无外部依赖，无 Xcode 项目
- 目标平台 macOS 12.0+ (Monterey)
- Bundle ID: `com.claude.usagebar`
- 使用 `NSUserNotification`（已废弃但免签名可用）
- 通知阈值：25%、50%、75%、90%
