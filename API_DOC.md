# Matisu 巨魔助手 API 文档

> **版本**: 1.0  
> **端口**: 8588  
> **协议**: HTTP  
> **运行环境**: iOS (TrollStore 安装，非越狱/越狱均支持)

---

## 概述

Matisu 巨魔助手通过 TrollStore 安装到 iOS 设备后，在后台运行一个 HTTP 服务（端口 8588），提供远程安装 `.tipa` 文件和自动启动 App 的能力。

### 核心特性

| 特性 | 说明 |
|------|------|
| 静默安装 | 通过 `trollstorehelper` 以 root 权限直接安装 tipa，无需用户确认 |
| 静默卸载 | 通过 `trollstorehelper` 以 root 权限卸载指定 App |
| 自动启动 | 安装完成后可自动启动指定 App（支持多个） |
| 后台常驻 | App 被划掉后 supervisor 进程存活，API 继续可用 |
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
  "port": 8588
}
```

#### 响应字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | string | 固定值，标识服务名称 |
| `port` | int | 服务端口号 |

---

### 2. 安装 tipa（核心接口）

下载 tipa 文件并以 root 权限静默安装到设备，可选安装后自动启动 App。

```
GET /install?url=<tipa下载地址>&launch=<bundle_id>
```

#### 参数说明

| 参数 | 必填 | 说明 |
|------|------|------|
| `url` | 是 | tipa 文件的 HTTP 下载地址（需 URL 编码） |
| `launch` | 否 | 安装成功后自动启动的 App bundle ID，支持三种格式 |

#### `launch` 参数格式

| 格式 | 说明 | 示例 |
|------|------|------|
| 单个 bundle ID | 启动一个 App | `launch=com.example.app` |
| 逗号分隔多个 | 依次启动多个 App，**每个间隔 10 秒** | `launch=com.app1,com.app2,com.app3` |
| `true` | 自动从 trollstorehelper 输出解析 bundle ID 并启动 | `launch=true` |

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

- App 启动时通过 `posix_spawn` 拉起独立的 `matisusupervisor` 进程
- supervisor 调用 `setsid()` 脱离 App 进程组，挂到 launchd 名下
- App 被划掉时，supervisor 不受影响，API 继续可用
- **注意**：重启手机后需要手动打开一次 App 来拉起 supervisor（非越狱限制）

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
| 连接超时 | App 未启动或 supervisor 未运行 | 在设备上打开一次 Matisu 巨魔助手 App |
| `exitCode` 非 0 | tipa 下载失败或文件损坏 | 检查 url 参数是否可访问 |
| `launch` 中 `ret=7` | App 未安装成功 | 检查 exitCode 和 output 日志 |
| `launch` 中 `ret=9` | supervisor 缺少 entitlement | 重新安装最新版 tipa |
| `method` 为 `dlopen_failed` | trollstorehelper 未找到 | 确认设备已安装 TrollStore |
| `download_failed` | tipa 下载地址不可达 | 确保设备能访问该 URL |

---

## 注意事项

1. **tipa 下载地址**：必须是设备能够直接访问的 HTTP 地址。如果 tipa 在本地 PC 上，需要先搭建 HTTP 服务（如 `python3 -m http.server`）。

2. **多个 App 启动间隔**：使用逗号分隔的多个 bundle ID 时，从第二个 App 开始，每个启动前等待 10 秒，确保上一个 App 完成初始化。

3. **自安装限制**：不能用此 API 安装 Matisu 巨魔助手自身（trollstorehelper 替换 App 会杀掉关联进程导致连接断开）。更新自身需通过 SSH + `sudo trollstorehelper install` 方式。

4. **重启后需手动启动**：非越狱环境下，重启手机后需要手动打开一次 App 来拉起 supervisor。越狱环境可通过 LaunchDaemon 实现开机自启。

5. **URL 编码**：如果 tipa 地址包含特殊字符（如 `&`、`=`、空格），需要 URL 编码。

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
