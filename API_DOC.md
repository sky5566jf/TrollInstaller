# M巨魔助手 API 文档

> **版本**: 1.2  
> **端口**: 8588  
> **协议**: HTTP  
> **运行环境**: iOS (TrollStore 安装，非越狱/越狱均支持)

---

## 概述

M巨魔助手通过 TrollStore 安装到 iOS 设备后，在后台运行一个 HTTP 服务（端口 8588），提供远程安装 `.tipa`/`.ipa` 文件和自动启动 App 的能力。

### 核心特性

| 特性 | 说明 |
|------|------|
| 静默安装 | 通过 `trollstorehelper` 以 root 权限直接安装 tipa/ipa，无需用户确认 |
| 静默卸载 | 通过 `trollstorehelper` 以 root 权限卸载指定 App |
| 自动启动 | 安装完成后可自动启动指定 App（支持多个），内置延迟+重试机制 |
| 独立启动 | 仅启动已安装的 App（不安装），支持多个 + 自定义间隔（`/launch`） |
| 端口健康检查 | 定时检测指定端口（8182/3333）是否存活，未监听则自动拉起对应 App（`/ports` 查看状态） |
| 后台常驻 | App 被划掉后 supervisor 进程存活，API 继续可用 |
| 启动成功提示 | 手动打开 App 后，轮询确认 8588 服务真正就绪，即在 App 内悬浮显示小横幅「巨魔助手启动成功」（约 2.5s 后退出，无需通知权限，UI 在主线程渲染） |
| 跨平台调用 | 标准 HTTP 接口，任何设备/语言均可调用 |

---

## API 端点

### 1. 健康检查

检查 API 服务是否在线，获取服务信息。

```
GET /
```

#### 请求示例

```bash
curl http://<设备IP>:8588/
```

#### 响应示例

```json
{
  "status": "Matisu Troll Assistant API",
  "version": "1.2",
  "port": 8588
}
```

#### 响应字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | string | 固定值，标识服务名称 |
| `version` | string | 软件版本号（取自 `CFBundleShortVersionString`） |
| `port` | int | 服务端口号 |

> **`GET /status`**：返回更详细的运行状态，同样包含 `version` 字段，外加 `supervisor`（pid / running）与 `trollstorehelper` 路径。示例：
> ```json
> {
>   "status": "ok",
>   "version": "1.2",
>   "port": 8588,
>   "supervisor": { "pid": 1234, "running": true },
>   "trollstorehelper": "/var/containers/.../TrollStore.app/trollstorehelper"
> }
> ```

---

### 2. 安装 tipa/ipa（核心接口）

下载 tipa/ipa 文件并以 root 权限静默安装到设备，可选安装后自动启动 App。

> **支持格式**：`.tipa`（TrollStore 专用）和 `.ipa`（标准 IPA）均可。trollstorehelper 读取文件内容（zip 格式），不依赖后缀名，会自动应用 CoreTrust bypass 签名。

```
GET /install?url=<下载地址>&launch=<bundle_id>
```

#### 参数说明

| 参数 | 必填 | 说明 |
|------|------|------|
| `url` | 是 | tipa/ipa 文件的 HTTP 下载地址（需 URL 编码） |
| `launch` | 否 | 安装成功后自动启动的 App bundle ID，支持三种格式 |

#### `launch` 参数格式

| 格式 | 说明 | 示例 |
|------|------|------|
| 单个 bundle ID | 启动一个 App | `launch=com.example.app` |
| 逗号分隔多个 | 依次启动多个 App，**每个间隔 10 秒** | `launch=com.app1,com.app2,com.app3` |
| `true` | 自动从 trollstorehelper 输出解析 bundle ID 并启动 | `launch=true` |

> **`launch=true` 解析策略（三层）**：
> 1. 从输出 `ID: <bundle_id>` 行提取
> 2. 从 `[installApp] new app path: <path>` 提取路径并读取 Info.plist 的 CFBundleIdentifier
> 3. 正则兜底：从输出中搜索 reverse-DNS 格式字符串（com./org./net./io./live./app. 前缀）

> **启动重试机制**：安装成功后先等待 2 秒让 Installd 完成系统注册，再启动 App。若启动失败（exitCode ≠ 0），自动间隔 3 秒重试，最多尝试 3 次。

#### 请求示例

**仅安装，不启动：**
```bash
curl "http://192.69.0.41:8588/install?url=http://192.69.0.24:8878/Geranium1.1.4.tipa"
```

**安装 + 启动单个 App：**
```bash
curl "http://192.69.0.41:8588/install?url=http://192.69.0.24:8878/Geranium1.1.4.tipa&launch=live.cclerc.geranium"
```

**安装 + 自动解析 bundle ID 并启动：**
```bash
curl "http://192.69.0.41:8588/install?url=http://192.69.0.24:8878/Geranium1.1.4.tipa&launch=true"
```

**安装 + 启动多个 App（间隔 10 秒）：**
```bash
curl "http://192.69.0.41:8588/install?url=http://192.69.0.24:8878/Geranium1.1.4.tipa&launch=live.cclerc.geranium,com.matisu.trollassistant"
```

#### 响应示例

**安装成功（无 launch）：**
```json
{
  "status": "ok",
  "url": "http://192.69.0.24:8878/Geranium1.1.4.tipa",
  "method": "trollstorehelper",
  "exitCode": 0,
  "output": "[installApp] new app path: ...\nID: live.cclerc.geranium UUID: ...\n...",
  "launch": []
}
```

**安装成功 + 启动单个 App：**
```json
{
  "status": "ok",
  "url": "http://192.69.0.24:8878/Geranium1.1.4.tipa",
  "method": "trollstorehelper",
  "exitCode": 0,
  "output": "...",
  "launch": [
    {
      "bundleId": "live.cclerc.geranium",
      "result": "exitCode:0|[supervisor] --launch mode: bundleId=live.cclerc.geranium\n[supervisor] SBSLaunchAndOptions(5param) ret=0\n..."
    }
  ]
}
```

**安装成功 + 启动多个 App：**
```json
{
  "status": "ok",
  "url": "http://192.69.0.24:8878/Geranium1.1.4.tipa",
  "method": "trollstorehelper",
  "exitCode": 0,
  "output": "...",
  "launch": [
    {
      "bundleId": "live.cclerc.geranium",
      "result": "exitCode:0|[supervisor] SBSLaunchAndOptions(5param) ret=0\n..."
    },
    {
      "bundleId": "com.matisu.trollassistant",
      "result": "exitCode:0|[supervisor] SBSLaunchAndOptions(5param) ret=0\n..."
    }
  ]
}
```

**安装失败：**
```json
{
  "status": "error",
  "url": "http://192.69.0.24:8878/Geranium1.1.4.tipa",
  "method": "trollstorehelper",
  "exitCode": 1,
  "output": "...错误信息...",
  "launch": []
}
```

#### 响应字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | string | `"ok"` 成功，`"error"` 失败 |
| `url` | string | 请求的 tipa 下载地址 |
| `method` | string | 安装方法，通常为 `"trollstorehelper"` |
| `exitCode` | int | trollstorehelper 退出码，`0` = 成功 |
| `output` | string | trollstorehelper 的完整输出日志 |
| `launch` | array | 每个启动 App 的结果，无 launch 参数时为空数组 |

#### `launch` 数组元素字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `bundleId` | string | 启动的 App bundle ID |
| `result` | string | 启动结果，格式为 `exitCode:<码>|<supervisor输出>` |

#### `result` 字段解读

| 内容 | 含义 |
|------|------|
| `exitCode:0` | 启动成功 |
| `SBSLaunchAndOptions(5param) ret=0` | SBS 启动方法返回成功 |
| `SBSLaunch(2param) ret=0` | SBS 简化启动方法返回成功 |
| `exitCode:1` + `ALL launch methods failed` | 所有启动方法均失败 |
| `ret=9` | 缺少 entitlement（不应出现，已修复） |
| `ret=7` | App 未安装 |

---

### 3. 卸载 App

通过 `trollstorehelper uninstall` 以 root 权限卸载指定 App。

```
GET /uninstall?bundle_id=<bundle_id>
```

#### 参数说明

| 参数 | 必填 | 说明 |
|------|------|------|
| `bundle_id` | 是 | 要卸载的 App bundle identifier |

#### 请求示例

```bash
curl "http://192.69.0.41:8588/uninstall?bundle_id=live.cclerc.geranium"
```

#### 响应示例

**卸载成功：**
```json
{
  "status": "ok",
  "bundleId": "live.cclerc.geranium",
  "method": "trollstorehelper",
  "exitCode": 0,
  "output": "..."
}
```

**卸载失败（App 未安装）：**
```json
{
  "status": "error",
  "bundleId": "live.cclerc.geranium",
  "method": "trollstorehelper",
  "exitCode": 1,
  "output": "...错误信息..."
}
```

**缺少参数：**
```json
{
  "status": "error",
  "msg": "bundle_id required"
}
```

#### 响应字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | string | `"ok"` 成功，`"error"` 失败 |
| `bundleId` | string | 请求卸载的 App bundle ID |
| `method` | string | 卸载方法，通常为 `"trollstorehelper"` |
| `exitCode` | int | trollstorehelper 退出码，`0` = 成功 |
| `output` | string | trollstorehelper 的完整输出日志 |

---

### 4. 启动已安装 App（仅启动，不安装）

启动设备上**已安装**的 App（不重新下载/安装），支持依次启动多个 + 自定义间隔。适用于「装完就走、之后单独拉起」的场景，例如先启动 `com.matisu.one.nxs`，间隔若干秒再启动 `com.matisu.xcs`。

```
GET /launch?apps=<bundle_id1>,<bundle_id2>&interval=<秒>
```

#### 参数说明

| 参数 | 必填 | 说明 |
|------|------|------|
| `apps` | 是 | 要启动的 App bundle ID，逗号分隔支持多个（别名 `bundle_ids=`） |
| `interval` | 否 | 每个 App 启动之间的等待间隔（秒），默认 5，范围 1–60 |

> **说明**：`interval` 仅作用于「第 2 个及之后」的 App 之前——第一个 App 立即启动。每个 App 内部仍沿用 `launchApp` 的失败重试（最多 3 次，间隔 3 秒）。

#### 请求示例

**启动单个 App：**
```bash
curl "http://192.69.0.41:8588/launch?apps=com.matisu.one.nxs"
```

**依次启动两个 App，间隔 5 秒（常用场景）：**
```bash
curl "http://192.69.0.41:8588/launch?apps=com.matisu.one.nxs,com.matisu.xcs&interval=5"
```

**依次启动多个 App，间隔 10 秒：**
```bash
curl "http://192.69.0.41:8588/launch?apps=com.app1,com.app2,com.app3&interval=10"
```

#### 响应示例

**启动成功：**
```json
{
  "status": "ok",
  "interval": 5,
  "launches": [
    {
      "bundleId": "com.matisu.one.nxs",
      "result": "exitCode:0|[supervisor] --launch mode: bundleId=com.matisu.one.nxs\n[supervisor] SBSLaunchAndOptions(5param) ret=0\n..."
    },
    {
      "bundleId": "com.matisu.xcs",
      "result": "exitCode:0|[supervisor] SBSLaunchAndOptions(5param) ret=0\n..."
    }
  ]
}
```

**缺少参数：**
```json
{
  "status": "error",
  "msg": "apps required (comma-separated bundle ids)"
}
```

#### 响应字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | string | `"ok"` 成功 |
| `interval` | int | 实际使用的启动间隔（秒） |
| `launches` | array | 每个启动 App 的结果，元素含 `bundleId` 与 `result` |

> **与 `/install?launch=` 的区别**：`/install` 是「下载安装 + 启动」，`/launch` 只启动不安装。若要启动刚安装完的 App，用 `/install` 的 `launch` 参数（内置 2 秒 Installd 注册延迟）；若要启动早已装好的 App，用 `/launch`。

---

## 端口健康检查（自动拉起守护）

supervisor 内置一个定时任务，周期性检测指定端口是否在监听，若端口未存活则自动拉起对应 App，用于保证关键服务始终在线。

**默认监控配置：**

| 端口 | 对应 App | 行为 |
|------|----------|------|
| `8182` | `com.matisu.xcs` | 端口未监听 → 自动拉起 xcs |
| `3333` | `com.matisu.one.nxs` | 端口未监听 → 自动拉起 nxs |

**检测参数：**

| 参数 | 默认值 | 说明 |
|------|--------|------|
| 检测间隔 | 60 秒 | 每 60 秒扫描一次所有映射端口 |
| 二次确认延迟 | 3 秒 | 端口没监听先等 3 秒再探，避免误判 App「启动中」 |
| 拉起冷却 | 300 秒 | 同一端口拉起后 5 分钟内不再重复拉起，防止 App 崩溃循环导致的启动风暴 |

> **资源占用**：健康检查运行在 supervisor 进程内的 GCD 定时器，**不新建进程**。空闲时 CPU ≈ 0%，常驻内存增量可忽略（约 +0.2–0.5 MB）。仅在端口未监听时才触发一次 `spawnAsRoot + SBSLaunch`。

### /ports — 查看端口健康检查状态

```
GET /ports
```

返回当前各端口的监听状态与最近一次拉起时间，便于真机验证健康检查是否生效。

**响应示例：**
```json
{
  "status": "ok",
  "interval": 60,
  "cooldown": 300,
  "ports": [
    {"port": 8182, "bundle": "com.matisu.xcs", "listening": true, "lastLaunchAgoSec": null},
    {"port": 3333, "bundle": "com.matisu.one.nxs", "listening": false, "lastLaunchAgoSec": 42}
  ]
}
```

**响应字段：**

| 字段 | 类型 | 说明 |
|------|------|------|
| `interval` | int | 检测间隔（秒） |
| `cooldown` | int | 拉起冷却（秒） |
| `ports` | array | 每个端口的状态，含 `port` / `bundle` / `listening` / `lastLaunchAgoSec`（距上次拉起秒数，`null`=从未拉起） |

---

## 启动成功提示（应用内小横幅）

手动打开 App 后，App 会先拉起 supervisor，再**轮询本地 HTTP 服务 `http://127.0.0.1:8588/status`**，当确认服务真正监听并响应 `200` 时，在 App 自身窗口上**悬浮显示一条小横幅**：

- **文案**：`巨魔助手启动成功`
- 横幅位于界面顶部，带轻微放大淡入动画，约 1.5 秒后 App 主动退出（bootstrap-only）
- **无需任何通知权限**，只要手动打开 App 就必见（不依赖系统通知开关）

### 行为细节

| 项目 | 说明 |
|------|------|
| 轮询方式 | GCD 串行定时器，每 250ms 探测一次 `127.0.0.1:8588/status` |
| 就绪判定 | HTTP 返回状态码 `200` 即视为就绪 |
| 超时处理 | 10 秒内未就绪则安静退出，**不弹提示**（服务可能本就仅靠 supervisor 运行） |
| 显示方式 | 应用内 `UIWindow` 悬浮横幅（非系统通知），前台可见期间显示约 1.5s |
| 权限 | 无，不申请通知权限，拒绝通知也不会影响提示 |
| ATS 例外 | Info.plist 加 `NSAllowsLocalNetworking` 放行 `127.0.0.1` 回环明文 HTTP 探测 |

> **与系统通知的区别**：系统通知在 App 退出后仍可显示、但需用户授权；本方案改为应用内横幅，牺牲了「退出后仍显示」、换来了「零权限、必见」。后台冷启动唤醒（NEHotspotHelper）因无前台界面，不会显示此横幅。

---

## 工作原理

```
客户端请求
    │
    ▼
┌─────────────────────────────┐
│  HTTP Server (端口 8588)     │
│  运行在 matisusupervisor 中  │
└──────────┬──────────────────┘
           │
           ▼
┌─────────────────────────────┐
│  1. 下载 tipa 到 /tmp        │
│     (NSData dataWithContents) │
└──────────┬──────────────────┘
           │
           ▼
┌─────────────────────────────┐
│  2. spawnAsRoot 提权          │
│     (persona_np API)         │
│     → 以 root 身份运行        │
└──────────┬──────────────────┘
           │
           ▼
┌─────────────────────────────┐
│  3. trollstorehelper install │
│     (CoreTrust bypass 签名)  │
│     → 静默安装到设备          │
└──────────┬──────────────────┘
           │
           ▼ (如果有 launch 参数)
┌─────────────────────────────┐
│  4. spawnAsRoot supervisor   │
│     --launch <bundle_id>     │
│     → SBS 启动 App            │
│     (多个 App 间隔 10 秒)     │
└─────────────────────────────┘
```

### 后台常驻机制

- App 启动（被用户打开 / 被 NEHotspotHelper 冷启动唤醒）后，通过 `posix_spawn` 拉起独立的 `matisusupervisor` 进程，**随后 App 进程主动退出**（bootstrap-only 模式），仅保留 supervisor 常驻
- supervisor 调用 `setsid()` 脱离 App 进程组，挂到 launchd 名下，**独力提供 8588 API 服务**
- 因此整体常驻内存仅约 3–6 MB（纯 Foundation 守护进程），UI App 不再驻留占用 15–40 MB
- App 被划掉 / 已退出时，supervisor 不受影响，API 继续可用
- **注意**：重启手机后需要系统连上 WiFi（触发 NEHotspotHelper）自动唤醒 App 一次来拉起 supervisor（纯巨魔版非越狱的唯一冷启动路径）；越狱环境可用 LaunchDaemon 实现无 WiFi 自启

---

## 使用场景

### 场景 1：批量部署 App 到多台设备

```bash
# 设备列表
DEVICES=("192.69.0.41" "192.69.0.42" "192.69.0.43")
TIPA_URL="http://192.69.0.24:8878/Geranium1.1.4.tipa"
BUNDLE_ID="live.cclerc.geranium"

for ip in "${DEVICES[@]}"; do
  echo "Installing to $ip..."
  curl -s "http://$ip:8588/install?url=$TIPA_URL&launch=$BUNDLE_ID"
  echo
done
```

### 场景 2：Python 脚本调用

```python
import urllib.request
import json

def install_and_launch(device_ip, tipa_url, bundle_ids=None):
    """安装 tipa 并可选启动 App"""
    url = f"http://{device_ip}:8588/install?url={tipa_url}"
    if bundle_ids:
        # 支持单个字符串或列表
        if isinstance(bundle_ids, list):
            launch = ",".join(bundle_ids)
        else:
            launch = bundle_ids
        url += f"&launch={launch}"

    resp = urllib.request.urlopen(url, timeout=120)
    result = json.loads(resp.read().decode())

    print(f"安装状态: {result['status']}")
    print(f"退出码: {result['exitCode']}")

    if result.get('launch'):
        for item in result['launch']:
            print(f"  启动 {item['bundleId']}: {item['result'][:80]}")

    return result

# 示例：安装 Geranium 并自动启动
install_and_launch(
    "192.69.0.41",
    "http://192.69.0.24:8878/Geranium1.1.4.tipa",
    "live.cclerc.geranium"
)

# 示例：安装后启动多个 App
install_and_launch(
    "192.69.0.41",
    "http://192.69.0.24:8878/Geranium1.1.4.tipa",
    ["live.cclerc.geranium", "com.matisu.trollassistant"]
)
```

### 场景 3：自动解析 bundle ID

当不确定 tipa 的 bundle ID 时，使用 `launch=true` 让 API 自动从安装日志解析：

```bash
curl "http://192.69.0.41:8588/install?url=http://192.69.0.24:8878/UnknownApp.tipa&launch=true"
```

> API 会从 trollstorehelper 输出的 `ID: <bundle_id> UUID: ...` 行提取 bundle ID。

---

## 错误排查

| 问题 | 可能原因 | 解决方案 |
|------|---------|---------|
| 连接超时 | App 未启动或 supervisor 未运行 | 在设备上打开一次 M巨魔助手 App |
| `exitCode` 非 0 | 文件下载失败或文件损坏 | 检查 url 参数是否可访问，确认 tipa/ipa 文件有效 |
| `launch` 中 `ret=7` | App 未安装成功或 Installd 尚未注册 | 已内置 2s 延迟 + 3 次重试，若仍失败检查 exitCode 和 output |
| `launch` 中 `ret=9` | supervisor 缺少 entitlement | 重新安装最新版 tipa |
| `launch` 中 `no_bundle_id` | `launch=true` 时无法从输出解析 bundle ID | 改为显式传 bundle ID：`launch=com.xxx.app` |
| `launch` 中 `[failed after 3 attempts]` | 3 次重试均失败 | 检查 App 是否真正安装成功，查看 output 日志 |
| `method` 为 `dlopen_failed` | trollstorehelper 未找到 | 确认设备已安装 TrollStore |
| `download_failed` | 文件下载地址不可达 | 确保设备能访问该 URL |

---

## 注意事项

1. **支持格式**：`.tipa`（TrollStore 专用）和 `.ipa`（标准 IPA）均可安装。trollstorehelper 不依赖后缀名，会自动应用 CoreTrust bypass 签名。

2. **tipa/ipa 下载地址**：必须是设备能够直接访问的 HTTP 地址。如果文件在本地 PC 上，需要先搭建 HTTP 服务（如 `python3 -m http.server`）。

3. **多个 App 启动间隔**：使用逗号分隔的多个 bundle ID 时，从第二个 App 开始，每个启动前等待 10 秒，确保上一个 App 完成初始化。

4. **启动重试机制**：安装成功后自动等待 2 秒（Installd 注册延迟），再启动 App。若启动失败，自动重试最多 3 次（间隔 3 秒），应对刚安装完 App 尚未在系统中完全就绪的时序问题。

5. **自安装限制**：不能用此 API 安装 M巨魔助手自身（trollstorehelper 替换 App 会杀掉关联进程导致连接断开）。更新自身需通过 SSH + `sudo trollstorehelper install` 方式。

6. **重启后需手动启动**：非越狱环境下，重启手机后需要手动打开一次 App 来拉起 supervisor。越狱环境可通过 LaunchDaemon 实现开机自启。

7. **URL 编码**：如果下载地址包含特殊字符（如 `&`、`=`、空格），需要 URL 编码。

---

## 技术规格

| 项目 | 值 |
|------|-----|
| HTTP 端口 | 8588 |
| 请求方法 | GET |
| 响应格式 | JSON |
| Content-Type | application/json |
| CORS | `Access-Control-Allow-Origin: *`（支持浏览器跨域调用） |
| 连接模式 | Connection: close（短连接） |
| 安装超时 | 无硬限制（取决于 tipa 下载和安装时间） |
| 并发支持 | 单线程处理（排队执行） |
