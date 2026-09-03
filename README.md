# DMM Proxy API

基于 **OpenResty (nginx + Lua)** 实现的 DMM 资源代理服务。它运行在一台能访问日本节点（如 TUN 全局代理 / 日本 VPS）的主机上，帮助客户端绕过 DMM 的地区封锁 / 403，提供封面、剧照和预告片的直链访问与视频流式转发。

> 本项目"代理"的是 DMM 官方公开的预告片与封面/剧照图床资源，列表信息本身公开可访问，这里仅充当一个不受地区限制的转发节点。

---

## 特性

- **封面 / 剧照**：`/api/cover/:id` 返回 2K 高清封面（`awsimgsrc`）、标准封面与直链及代理路径；`/api/film_sample/:id` 通过 DMM 官方 FANZA TV GraphQL API 一次性返回全部高清剧照
- **预告片**：`/api/trailer/:id` 返回多个码率预告片的直链及代理路径；探测从最高档（`hhb`/1080p）开始，只返回最高三档
- **预告片直链**：`/api/trailer_direct/:id` 并发请求 AVWikiDB / DMM / JAVDatabase，谁先成功用谁，并带 `source`；命中结果缓存 7 天（`lua_shared_dict`）
- **智能 CID 探测**：番号（如 `ABP-477`）自动转成 DMM 内部多个候选 CID（如 `abp00477`、`abp0477`、`1abp477`）逐一探测，命中第一个可用项
- **快速存在性探测**：用 `Range: bytes=0-1023` 请求，接受 `200/206/416`，探测预告片由 37s 降到约 1s
- **流式视频代理**：`/proxy/video/*` 支持 HTTP Range，可在播放器内拖动进度条；自动带浏览器 UA 与 DMM 的 `Referer` 避免 CDN 403
- **可选 HTTPS (SSL)**：证书目录存在即自动启用 443；无证书则纯 HTTP，开箱即用
- **防滥用**：
  - **`/api/*`**（cover/trailer/film_sample）**始终**需要 `Authorization: Bearer <token>`
  - `DMM_API_PROTECT=on` 时，`/api/*` 返回的 `proxy.*` 附带 `DMM_SIGN_TTL` 秒内有效的 **HMAC-SHA256 签名 URL**；`/proxy/*` 需凭该签名访问，并有单 IP 限流与可选 IP 白名单
  - `DMM_API_PROTECT=off` 时，`/api/*` 返回的 `proxy.*` 为普通路径（无签名），`/proxy/*` 完全开放

---

## 目录结构

```
dmm-proxy-api/
├── Dockerfile              # 基于 openresty/openresty:alpine
├── docker-compose.yml      # 一键编排，环境变量透传
├── docker-compose.hub.yml  # 从 Docker Hub 拉镜像的编排文件
├── .env                    # 本地运行配置（注意：勿提交真实 token）
├── .env.example            # 配置模板
├── api.md                  # 接口详细文档（中文）
├── api.http                # REST Client 测试请求
├── conf/
│   ├── nginx.conf          # nginx + lua 路由、代理、限流 zone（改动需 rebuild）
│   └── dmm.ssl.conf.template # HTTPS(443) server 配置模板（entrypoint 按需启用）
├── docker/entrypoint.sh    # 容器入口：检测证书，有则启用 SSL，无则纯 HTTP
├── certs/                  # 存放 SSL 证书（fullchain.pem + private.key），不入库
├── lua/                    # 业务逻辑（docker volume 挂载，改后可 reload）
│   ├── config.lua          # 配置读取、CID 转换、代理路径与签名、IP 白名单工具
│   ├── router.lua          # 鉴权 + 路由分发（check_auth）
│   ├── access.lua          # gate（IP 白名单 + 限流）与 require_sig（签名校验）
│   ├── sign.lua            # HMAC-SHA256 签名 / 验签
│   ├── web.lua             # 基于 vendored lua-resty-http 的探测与抓取
│   ├── api_cover.lua       # /api/cover 实现
│   ├── api_film_sample.lua # /api/film_sample 实现（FANZA TV GraphQL）
│   └── api_trailer.lua     # /api/trailer 实现
│   └── api_trailer_direct.lua # /api/trailer_direct 实现（多源并发 + 7 天缓存）
└── vendor/resty/           # 本地 vendor 的 lua-resty-http（纯 Lua，无需额外依赖）
```

---

## 快速开始

### 1. 环境要求

- Docker + Docker Compose
- 宿主机可访问日本节点（用于绕过 DMM 地区封锁）。本项目开发时宿主机通过 TUN 接入日本节点，Docker 默认走宿主机网络栈，无需额外配置；若运行在日本 VPS 则天然满足。

### 2. 配置

复制 `.env.example` 为 `.env` 并填写：

```bash
cp .env.example .env
# 编辑 .env，至少修改 DMM_AUTH_TOKEN
```

### 3. 环境变量说明

| 变量 | 默认 | 说明 |
|------|------|------|
| `DMM_AUTH_TOKEN` | `change-me-in-production` | `/api/*` 的 Bearer token，同时作为签名 URL 的 HMAC 密钥。**生产必改**：`openssl rand -hex 32` |
| `DMM_API_PROTECT` | `on` | 代理侧防滥用总开关，`on/true/1/yes` 开启，`off/空` 关闭。`on` 时 `/api/*` 返回的 proxy 附带签名+时效，`/proxy/*` 需凭签名访问且有限流/IP 白名单；`off` 时 proxy 无签名、`/proxy/*` 完全开放 |
| `DMM_SIGN_TTL` | `220` | on 时签名 URL 的有效秒数 |
| `DMM_RATE_PER_MIN` | `240` | on 时单 IP 每分钟请求上限 |
| `DMM_ALLOW_IPS` | 空 | on 时可选的 IP 白名单，逗号分隔 IP 与 CIDR（如 `1.2.3.4,203.0.113.0/24`），空=放行全部 |
| `DMM_PROXY_PORT` | `80` | 宿主机对外 HTTP 端口 |
| `DMM_PROXY_SSL_PORT` | `443` | 宿主机对外 HTTPS 端口 |
| `DMM_CERT_DIR` | `/etc/ssl/dmm` | 容器内证书目录 |
| `DMM_CERT_FILE` | `fullchain.pem` | 证书文件名 |
| `DMM_CERT_KEY` | `private.key` | 私钥文件名 |

### 4. 启动

```bash
docker compose up -d --build

# 验证
curl http://localhost:8080/health    # -> ok
```

> 说明：
> - `conf/nginx.conf` 在 build 时被 COPY 进镜像，改动后需 `docker compose up -d --build`
> - `lua/` 通过 volume 挂载进容器（`./lua:/etc/openresty/lua/:ro`），改逻辑后执行 `docker compose restart`（reload worker）即可

### 5. 启用 HTTPS (SSL)（可选）

容器启动时 `entrypoint.sh` 会自动检测证书目录：**存在证书即启用 443，否则纯 HTTP**。无需额外开关。

**放置证书**（默认从宿主机 `./certs/` 挂载）：

```bash
mkdir -p certs
# 将证书拷贝为固定文件名（可用环境变量覆盖）
cp /path/to/fullchain.pem certs/fullchain.pem
cp /path/to/private.key   certs/private.key

docker compose up -d --build
```

**验证**：

```bash
curl -k https://localhost:8443/health   # -> ok（HTTPS 已启用）
```

证书可用以下环境变量自定义文件名与路径：

| 变量 | 默认 | 说明 |
|------|------|------|
| `DMM_SSL_CERTS_DIR` | `./certs` | 宿主机证书目录（compose 挂载源） |
| `DMM_CERT_DIR` | `/etc/ssl/dmm` | 容器内证书路径 |
| `DMM_CERT_FILE` | `fullchain.pem` | 证书文件名 |
| `DMM_CERT_KEY` | `private.key` | 私钥文件名 |

> 证书文件**最少需要** `fullchain.pem`（或证书链）与 `private.key` 两个，才会启用 HTTPS；缺任一即退回纯 HTTP。

**从 Docker Hub 拉取镜像运行**（无需本地构建）：

```bash
docker compose -f docker-compose.hub.yml up -d
```

### 6. 尝试验证

```bash
HEADER="Authorization: Bearer <你的DMM_AUTH_TOKEN>"

# 封面
curl -s -H "$HEADER" http://localhost:8080/api/cover/SONE-128

# 剧照
curl -s -H "$HEADER" http://localhost:8080/api/film_sample/SSIS-497

# 预告片
curl -s -H "$HEADER" http://localhost:8080/api/trailer/SSIS-497
```

---

## 防护模式说明（`DMM_API_PROTECT`）

| 开关 | `/api/*` | `/proxy/*`（代理） |
|------|----------|---------------------|
| **on**（默认，推荐生产） | 需要 `Authorization: Bearer <token>`，返回的 `proxy.*` 附带 `?sig=&exp=` | **无需 token**，需 `DMM_SIGN_TTL` 内有效的**签名 URL** + 限流 + 可选 IP 白名单 |
| **off** | 需要 `Authorization: Bearer <token>`，返回的 `proxy.*` 为普通路径 | **无需 token**、无签名、不限流、无 IP 白名单 |

**on 时的签名 URL**

`/api/cover`、`/api/film_sample` 与 `/api/trailer` 返回的 `proxy.*` 字段是短时效签名链接：

```
/proxy/video/{path}?sig=<hex-hmac-sha256>&exp=<unix_ts>
```

- `exp` = 签发时间 + `DMM_SIGN_TTL`，过期即 `403`
- `sig` = `HMAC-SHA256(DMM_AUTH_TOKEN, request_uri .. ":" .. exp)`
- 即使链接泄露，也仅在 `DMM_SIGN_TTL` 秒内可用（默认 220s）

---

## API 概览

### 健康检查

```
GET /health
```
无需鉴权，返回 `ok`。

### 封面 / 剧照

```
GET /api/cover/:id
Authorization: Bearer <token>
```

**响应 `200`（节选）**

```json
{
  "id": "SONE-128",
  "cid": "sone00128",
  "cover": {
    "large": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/sone00128/sone00128pl.jpg",
    "hd": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/sone00128/sone00128pl.jpg",
    "sd": "https://pics.dmm.co.jp/digital/video/sone00128/sone00128pl.jpg",
    "small": "https://pics.dmm.co.jp/digital/video/sone00128/sone00128pt.jpg",
    "proxy": {
      "hd": "/proxy/aws/digital/video/sone00128/sone00128pl.jpg",
      "sd": "/proxy/pics/digital/video/sone00128/sone00128pl.jpg",
      "small": "/proxy/pics/digital/video/sone00128/sone00128pt.jpg"
    }
  }
}
```

### 剧照

```
GET /api/film_sample/:id
Authorization: Bearer <token>
```

通过 DMM 官方公开的 **FANZA TV GraphQL API**（`https://api.tv.dmm.co.jp/graphql`）一次性获取该番号的全部高清剧照（无需逐个探测，且能拿到 `2K` 大图）。

**响应 `200`（节选）**

```json
{
  "id": "SSIS-497",
  "cid": "ssis00497",
  "total": 10,
  "samples": [
    {
      "index": 1,
      "small": "https://awsimgsrc.dmm.co.jp/dig_white/digital/video/ssis00497/ssis00497-1.jpg",
      "large": "https://awsimgsrc.dmm.co.jp/dig_white/digital/video/ssis00497/ssis00497jp-1.jpg",
      "proxy": "/proxy/sample/digital/video/ssis00497/ssis00497jp-1.jpg"
    }
  ]
}
```

### 预告片

```
GET /api/trailer/:id
Authorization: Bearer <token>
```

**响应 `200`（节选）**

```json
{
  "id": "SSIS-497",
  "cid": "ssis00497",
  "trailers": [
    { "quality": "sm",  "bitrate": 300,  "url": "https://cc3001.dmm.co.jp/litevideo/freepv/s/ssi/ssis00497/ssis00497_sm_w.mp4",  "proxy": "/proxy/video/litevideo/freepv/s/ssi/ssis00497/ssis00497_sm_w.mp4" },
    { "quality": "mhb", "bitrate": 2500, "url": "https://cc3001.dmm.co.jp/litevideo/freepv/s/ssi/ssis00497/ssis00497_mhb_w.mp4", "proxy": "/proxy/video/litevideo/freepv/s/ssi/ssis00497/ssis00497_mhb_w.mp4" }
  ]
}
```

> 预告片码率档位：`sm`(300k) / `dm`(1000k) / `dmb`(1500k) / `mhb`(2500k)，仅返回探测存在的档位。

### 资源代理（`/proxy/*`）

| 路径 | 上游 | 说明 |
|------|------|------|
| `/proxy/aws/{path}` | `https://awsimgsrc.dmm.co.jp/pics_dig/{path}` | 2K 高清封面 |
| `/proxy/sample/{path}` | `https://awsimgsrc.dmm.co.jp/dig_white/{path}` | 高清剧照 |
| `/proxy/pics/{path}` | `https://pics.dmm.co.jp/{path}` | 标准图 |
| `/proxy/video/{path}` | `https://cc3001.dmm.co.jp/{path}` | 预告片视频，支持 Range |

访问 `/proxy/*` 时**无需携带 token**：
- `DMM_API_PROTECT=off` 时：直接用 `/api/*` 返回的原始 `proxy.*` 路径（无签名，完全开放）
- `DMM_API_PROTECT=on` 时：`/api/*` 返回的 `proxy.*` 已附带 `?sig=&exp=`，直接用即可；签名缺失/过期将返回 `403`

### 状态码

| 状态码 | 含义 |
|--------|------|
| `200` | 成功 |
| `206` | 部分内容（视频/图片 Range） |
| `400` | 参数缺失 |
| `401` | 缺少 `Authorization` 头（始终生效，`/api/*`） |
| `403` | token 无效；或 on 时签名无效/过期、IP 不在白名单 |
| `404` | 对应 DMM 资源未找到 |
| `429` | 超出单 IP 限流（on 时） |

---

## 工作原理

1. 客户端请求 `/api/cover/:id`、`/api/film_sample/:id` 或 `/api/trailer/:id`，携带 Bearer token；`router.check_auth()` 校验（无论 protect 开关均强制）。
2. `config.to_cids()` 将番号转为多个候选 CID。
3. 构建响应：直接 CDN 直链 + 本机代理路径。数据来源两种：
   - **封面 / 预告片**：逐一对 DMM CDN 做 `Range: bytes=0-1023` 的快速存在性探测（`web.lua`），命中第一个可用项
   - **剧照**：通过 FANZA TV GraphQL API（`api.tv.dmm.co.jp/graphql`）一次返回该 CID 的全部剧照
   当 `DMM_API_PROTECT=on` 时，代理路径经 `sign.lua` 绑定 `HMAC-SHA256(token, uri..":"..exp)` 签名并附 `exp`。
4. 客户端访问 `/proxy/*` 时（**无需 token**）：
   - `access.gate()`：on 时执行 IP 白名单 + 固定窗口限流（`ngx.shared.rate_limit`）
   - `access.require_sig()`：on 时校验签名与过期时间；off 时放行
5. nginx `proxy_pass` 转发到对应 DMM CDN，视频流关闭缓冲（支持拖动），图片按需转发。
6. 容器启动时 `entrypoint.sh` 检测证书：证书存在则额外启用 HTTPS(443) server 块（`include dmm.d/ssl.conf`），否则仅监听 HTTP(80)。

### 签名校验细节（`sign.lua`）

- 签名消息 = `request_uri .. ":" .. exp`，密钥 = `DMM_AUTH_TOKEN`
- 采用 **OpenResty 内置 `resty.openssl.hmac`**（`ngx.hmac_sha256` 在部分镜像不可用），输出 `resty.string.to_hex`
- 常量时间比较，防止时序侧信道
- `exp` 必须未过期，否则拒绝

---

## 指纹/调试建议

- 查看访问日志：`docker exec dmm-proxy tail -f /var/log/openresty/access.log`
- 查看错误/限流日志：`docker exec dmm-proxy tail -f /var/log/openresty/error.log`
- 检查 nginx 配置：`docker exec dmm-proxy /usr/local/openresty/bin/openresty -t`

---

## 安全提醒

- **生产必备**：设置强 `DMM_AUTH_TOKEN`（`openssl rand -hex 32`），并用 `DMM_ALLOW_IPS` 收紧到可信来源；把 `DMM_API_PROTECT` 保持为 `on`
- `DMM_API_PROTECT=off` 仅用于内网/调试环境——此时 `/proxy/*` 完全开放（无签名、无限流），链接一旦泄露可被任意转发
- `/health` 无鉴权，不返回敏感信息，可安全暴露

---

## 常见问题

**为什么 `/api/*` 在 on/off 模式下都要 token，而 `/proxy/*` 不用？**
这是刻意设计：`/api/*` 是"按番号探测并生成链接"的入口，**始终强制 token**，防止被匿名滥用（盗刷探测流量）；`/proxy/*` 则面向播放器/图片直连，不要求 token——`on` 时仅靠短时效签名（`sig`+`exp`）保护，`off` 时完全开放。

**改 nginx.conf 后不生效？**
`conf/nginx.conf` 在 build 时 COPY 进镜像，改动后需 `docker compose up -d --build`。改 `lua/*.lua` 则只需 `docker compose restart`。

**某番号返回 404？**
可能确实无对应资源（无预告片/封面命名特殊），或 CID 探测未命中全部变体。可检查 error.log 确认探测请求。

**视频播放卡顿/无法拖动？**
确认请求带了 `Range` 头并获得 `206`；`/proxy/video/*` 已关闭缓冲（`proxy_buffering off`）、`proxy_read_timeout 120s`。

**为什么 HTTPS 没生效？**
`entrypoint.sh` 要求 `/etc/ssl/dmm/` 下同时存在 `fullchain.pem` 与 `private.key` 才开始监听 443。检查：① 证书是否已放入宿主机 `./certs/`；② `docker logs dmm-proxy` 是否显示 `SSL enabled`；③ 证书文件是否有读取权限。
