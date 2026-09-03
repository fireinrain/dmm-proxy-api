# DMM Proxy API

基于 OpenResty (nginx + lua) 实现的 DMM 资源代理，通过日本节点（TUN）绕过 DMM 的地区封锁 / 403，为客户端提供封面、剧照和预告片的直链访问与视频流式转发。

- Base URL: `http://{host}:{DMM_PROXY_PORT}`（默认 `8080`）
- 鉴权方式: `Authorization: Bearer <token>`（token 由环境变量 `DMM_AUTH_TOKEN` 指定）
- 默认 `DMM_PROXY_PORT=80`、`DMM_PROXY_SSL_PORT=443`，详见 `.env`

---

## 防护开关（`DMM_API_PROTECT`）

`DMM_API_PROTECT` 控制**代理侧**的防滥用保护（签名 URL、限流、IP 白名单），取值：`on`/`true`/`1`/`yes`（开启）或 `off`/空（关闭）。

> 注意：**所有对外接口**（`/api/*` 与 `/proxy/*`）**始终需要 `Authorization: Bearer <token>`**（无论 `DMM_API_PROTECT` 是 `on` 还是 `off`）。该开关只额外控制 `/proxy/*` 是否需要签名、限流与 IP 白名单。

| 开关 | `/api/*` | `/proxy/*` |
|------|----------|------------|
| **on**（默认，推荐生产） | 需要 `Authorization: Bearer <token>` | 需要 `Bearer token` **且** `DMM_SIGN_TTL`（默认 220s）内有效的**签名 URL** + 限流 + 可选 IP 白名单 |
| **off** | 需要 `Authorization: Bearer <token>` | 需要 `Bearer token`，**不要求签名**、无限流/IP 白名单 |

辅助配置：

| 环境变量 | 说明 | 默认 |
|----------|------|------|
| `DMM_AUTH_TOKEN` | API token，同时作为签名 HMAC 密钥 | - |
| `DMM_SIGN_TTL` | 签名 URL 有效秒数 | `220` |
| `DMM_RATE_PER_MIN` | 单 IP 每分钟请求上限（on 时生效） | `240` |
| `DMM_ALLOW_IPS` | 可选 IP 白名单，逗号分隔 IP/CIDR，空=放行全部 | 空 |

### 签名 URL 说明（on 时）

`/api/cover`、`/api/film_sample` 和 `/api/trailer` 返回的 `proxy.*` 字段是短时效签名链接：
```
/proxy/video/{path}?sig=<hex-hmac>&exp=<unix_ts>
```
- `exp` = 签发时间 + `DMM_SIGN_TTL`，过期即 403
- `sig` = `HMAC-SHA256(DMM_AUTH_TOKEN, uri .. ":" .. exp)`
- 用于播放器/客户端直接拉流，可跨 IP 使用但仅在 `DMM_SIGN_TTL` 内有效

### 通用说明

所有 `/api/*` 接口**始终**需要携带请求头（无论 `DMM_API_PROTECT` 是 on 还是 off）：

```
Authorization: Bearer <DMM_AUTH_TOKEN>
```

| 状态码 | 含义 |
|--------|------|
| `200` | 成功 |
| `401` | 缺少 Authorization 头（始终生效，`/api/*` 与 `/proxy/*`） |
| `403` | token 无效；或 on 时签名无效/过期/IP 不在白名单 |
| `429` | 超出单 IP 限流（on 时） |
| `404` | 对应 DMM 资源未找到 |
| `400` | 参数缺失 |

`id`（番号）支持形如 `ABP-477`、`ssis497` 的输入，服务端内部会将其转换为多个候选的 DMM CID（如 `abp00477`、`abp0477`、`1abp477` 等）逐一探测，命中第一个可用项。

---

## 1. 健康检查

```
GET /health
```

无需鉴权。返回 `ok`。

---

## 2. 封面 / 剧照信息

```
GET /api/cover/:id
```

根据番号返回封面（2K 高清优先）、小图与全部剧照的直链以及本机代理路径。

**示例请求**

```http
GET http://localhost:8080/api/cover/SONE-128
Authorization: Bearer <token>
```

**示例响应 `200`**

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

**响应字段**

| 字段 | 说明 |
|------|------|
| `id` | 用户传入的番号（大写） |
| `cid` | 探测命中的 DMM 内容 ID |
| `cover.large` | 最优封面（2K 高清优先，其次标准） |
| `cover.hd` | 2K 高清封面（`awsimgsrc.dmm.co.jp`），可能不存在 |
| `cover.sd` | 标准封面（`pics.dmm.co.jp`） |
| `cover.small` | 小图 `pt.jpg` |
| `cover.proxy.hd/sd/small` | 经本机代理的路径（客户端据此避开 DMM 地区封锁） |

失败返回 `404`：

```json
{ "error": "not_found", "message": "Cover not found for id: ABP-477" }
```

---

## 3. 剧照（Film Sample）信息

```
GET /api/film_sample/:id
```

根据番号返回全部剧照（标准图 + 高清图）的直链与本机代理路径。

> 通过 DMM 官方公开的 **FANZA TV GraphQL API**（`https://api.tv.dmm.co.jp/graphql`）一次性获取全部剧照，无需逐个探测，响应快且可拿到 `2K` 高清大图（`awsimgsrc.dmm.co.jp/dig_white`）。

**示例请求**

```http
GET http://localhost:8080/api/film_sample/SSIS-497
Authorization: Bearer <token>
```

**示例响应 `200`**

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
    },
    {
      "index": 2,
      "small": "https://awsimgsrc.dmm.co.jp/dig_white/digital/video/ssis00497/ssis00497-2.jpg",
      "large": "https://awsimgsrc.dmm.co.jp/dig_white/digital/video/ssis00497/ssis00497jp-2.jpg",
      "proxy": "/proxy/sample/digital/video/ssis00497/ssis00497jp-2.jpg"
    }
  ]
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `id` | 用户传入的番号（大写） |
| `cid` | 探测命中的 DMM 内容 ID |
| `total` | 剧照总数 |
| `samples[].index` | 剧照序号（从 1 开始） |
| `samples[].small` | 标准剧照直链（`awsimgsrc.dmm.co.jp/dig_white`） |
| `samples[].large` | 高清剧照直链（`jp-N.jpg`） |
| `samples[].proxy` | 本机代理路径（推荐使用，可避开地区封锁） |

失败返回 `404`：

```json
{ "error": "not_found", "message": "No sample images found for id: ABP-477" }
```

---

## 4. 预告片信息

```
GET /api/trailer/:id
```

根据番号返回预告片的多个码率直链与本机代理路径。仅返回探测存在的码率。

**示例请求**

```http
GET http://localhost:8080/api/trailer/SSIS-497
Authorization: Bearer <token>
```

**示例响应 `200`**

```json
{
  "id": "SSIS-497",
  "cid": "ssis00497",
  "trailers": [
    { "quality": "sm",  "bitrate": 300,  "url": "https://cc3001.dmm.co.jp/litevideo/freepv/s/ssi/ssis00497/ssis00497_sm_w.mp4",  "proxy": "/proxy/video/litevideo/freepv/s/ssi/ssis00497/ssis00497_sm_w.mp4" },
    { "quality": "dm",  "bitrate": 1000, "url": "https://cc3001.dmm.co.jp/litevideo/freepv/s/ssi/ssis00497/ssis00497_dm_w.mp4",  "proxy": "/proxy/video/litevideo/freepv/s/ssi/ssis00497/ssis00497_dm_w.mp4" },
    { "quality": "dmb", "bitrate": 1500, "url": "https://cc3001.dmm.co.jp/litevideo/freepv/s/ssi/ssis00497/ssis00497_dmb_w.mp4", "proxy": "/proxy/video/litevideo/freepv/s/ssi/ssis00497/ssis00497_dmb_w.mp4" },
    { "quality": "mhb", "bitrate": 2500, "url": "https://cc3001.dmm.co.jp/litevideo/freepv/s/ssi/ssis00497/ssis00497_mhb_w.mp4", "proxy": "/proxy/video/litevideo/freepv/s/ssi/ssis00497/ssis00497_mhb_w.mp4" }
  ]
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `id` | 用户传入的番号（大写） |
| `cid` | 探测命中的 DMM 内容 ID |
| `trailers[].quality` | 码率档位：`sm`(300k) / `dm`(1000k) / `dmb`(1500k) / `mhb`(2500k) |
| `trailers[].bitrate` | 码率（kbps） |
| `trailers[].url` | DMM 预告片直链 |
| `trailers[].proxy` | 本机代理路径（推荐使用，可避开地区封锁） |

> 极少数片子没有预告片，返回 `404`：
> ```json
> { "error": "not_found", "message": "Trailer not found for id: SONE-128" }
> ```

---

## 5. 封面图片代理

```
GET /proxy/aws/{path}
GET /proxy/pics/{path}
```

把 DMM 图片 CDN 的请求经本机（日本节点）转发，客户端直接可访问而不被 DMM 地区限制挡掉。通常由 `/api/cover` 返回的 `proxy.*` 路径使用。

**鉴权**：请求需携带 `Authorization: Bearer <token>`（无论 on/off）；`on` 时另需有效签名 `?sig=&exp=`。

| 代理路径 | 上游 CDN |
|----------|----------|
| `/proxy/aws/{path}` | `https://awsimgsrc.dmm.co.jp/pics_dig/{path}`（2K 高清封面） |
| `/proxy/sample/{path}` | `https://awsimgsrc.dmm.co.jp/dig_white/{path}`（高清剧照） |
| `/proxy/pics/{path}` | `https://pics.dmm.co.jp/{path}`（标准） |

- 访问 `/proxy/*` 时（**无论 on/off**）**必须携带 `Authorization: Bearer <token>`**。
- `DMM_API_PROTECT=off` 时：带 token 即可，直接使用 `/api/cover` 返回的原始 `proxy.*` 路径（无签名）。
- `DMM_API_PROTECT=on` 时：`/api/cover` 返回的 `proxy.*` 已自带 `?sig=&exp=`，带 token + 签名直接使用即可；若去掉签名参数或已过期，返回 `403`。

**示例**（off 时的原始路径）

```http
GET /proxy/aws/digital/video/sone00128/sone00128pl.jpg
Authorization: Bearer <DMM_AUTH_TOKEN>

GET /proxy/pics/digital/video/sone00128/sone00128pl.jpg
Authorization: Bearer <DMM_AUTH_TOKEN>
```

响应为 `image/jpeg`，支持 Range。

---

## 6. 预告片视频流代理

```
GET /proxy/video/{path}
```

把 DMM 预告片 CDN（`cc3001.dmm.co.jp`）经本机（日本节点）代理转发，支持 HTTP Range（可在播放器内拖动进度条）。通常由 `/api/trailer` 返回的 `proxy` 路径使用。

- 请求头自动携带浏览器 UA 与 `Referer: https://www.dmm.co.jp/`，避免 CDN 403
- `proxy_buffering off`，边下边播
- **必须携带 `Authorization: Bearer <token>`**（无论 on/off）
- `DMM_API_PROTECT=on` 时，路径需带签名 `?sig=&exp=`（`/api/trailer` 返回时已附带），否则 `403`

**示例**（off 时的原始路径，on 时末尾追加 `?sig=&exp=`）

```http
GET /proxy/video/litevideo/freepv/s/ssi/ssis00497/ssis00497_mhb_w.mp4
Authorization: Bearer <DMM_AUTH_TOKEN>
```

响应 `Content-Type: video/mp4`，支持 `Range`（返回 `206 Partial Content`）。

---

## 鉴权失败响应

```json
{ "error": "unauthorized", "message": "Missing Authorization header. Use: Authorization: Bearer <token>" }   // 401
{ "error": "forbidden", "message": "Invalid token" }                                                         // 403
```
