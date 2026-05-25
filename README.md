# cc-deepseek-statusbar

Claude Code 状态栏增强插件 — 使用 Deepseek API 时，实时显示 Session token 消耗、今日 token 消耗、账户余额。

```
deepseek-v4-pro  think:high  ████░░░░░░ 42%  ~/my-project    ← 第一行：模型 · 思考模式 · 上下文 · 目录
12.5K · 2,343.9K · ¥14.44                                    ← 第二行：会话 token · 今日 token · 余额
```

## 效果

接入 Deepseek 模型后，状态栏分为两行显示（仅对 `deepseek-*` 模型显示）：

**第一行** — 模型名、思考模式、上下文窗口用量条、当前目录

**第二行** — token 统计与余额：

| 数值 | 含义 | 颜色 |
|------|------|------|
| `12.5K` | **当前 Session** 累计 token 消耗 (K=千) | 紫色 |
| `2,343.9K` | **今日** 累计 token 消耗 (带千分位) | 灰色 |
| `¥14.44` | **Deepseek 账户** 剩余余额 (CNY) | 绿色 |

- 切换到 Anthropic 模型时，第二行自动隐藏，仅显示第一行
- token 统计区分缓存命中/未命中，按 Deepseek 实际定价计算
- 启动时未收到会话数据前，显示 "waiting for session data" 占位
- 空闲状态（无 API 调用）显示 `tokens: 0`
- 余额未知时显示 `¥...`，后台异步刷新

## 前置条件

- **Claude Code** 已配置使用 Deepseek API（`ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic`）
- `ANTHROPIC_AUTH_TOKEN` 已设置为你的 Deepseek API Key
- `jq`、`curl`、`awk` 已安装（macOS 默认有 awk 和 curl，只需 `brew install jq`）

## 一键安装

```bash
curl -sSL https://raw.githubusercontent.com/harmonarch/cc-deepseek-statusbar/main/install.sh | bash
```

或者克隆后本地安装：

```bash
git clone https://github.com/harmonarch/cc-deepseek-statusbar.git
cd cc-deepseek-statusbar
bash install.sh
```

## 手动配置

如果不想用安装脚本，手动两步：

**1. 复制脚本**

```bash
cp statusline-command.sh ~/.claude/statusline-command.sh
chmod +x ~/.claude/statusline-command.sh
```

**2. 修改 `~/.claude/settings.json`**，添加：

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/statusline-command.sh"
}
```

重启 Claude Code 即可生效。

## 工作原理

```
Claude Code 状态栏 (每 ~300ms 调用脚本)
  │
  ├─ stdin JSON → jq 解析 model.id / token usage / session_id
  │
  ├─ 检测 model.id 是否匹配 deepseek-*
  │    │
  │    ├─ 是 → 通过 total_api_duration_ms 变化识别新 API 调用
  │    │        累加 token → /tmp/claude-deepseek/session_<id>.json
  │    │        累加 token → /tmp/claude-deepseek/daily_<日期>.json
  │    │        余额缓存  → /tmp/claude-deepseek/balance_cache.json (90s TTL, 异步刷新)
  │    │
  │    └─ 否 → 跳过第二行 token/余额显示
  │
  ├─ 空闲状态 → 第二行显示 "tokens: 0"，余额异步获取
  │
  └─ 输出两行：第一行模型/上下文/目录，第二行 token/余额
```

### Deepseek V4 Pro 定价 (CNY / 百万 tokens)

| 类型 | 单价 |
|------|------|
| 输入 (缓存未命中) | ¥3.00 |
| 输入 (缓存命中) | ¥0.025 |
| 输出 | ¥6.00 |

## 常见问题

**Q: 安装后状态栏没变化？**
重启 Claude Code 试试。如果还是不行，检查 `jq` 是否已安装：`which jq`

**Q: 余额显示 "¥..." ？**
网络问题或 API Key 失效。检查 `ANTHROPIC_AUTH_TOKEN` 是否正确，脚本会在后台自动重试。

**Q: Session token 数字偏低？**
安装后的当前 Session 会从零开始计数（之前的部分无法追溯），新 Session 完全准确。

**Q: 如何卸载？**
删除 `~/.claude/settings.json` 中的 `statusLine` 配置项，以及 `~/.claude/statusline-command.sh` 文件。
