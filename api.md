# DMM Proxy API

基于 OpenResty (nginx + lua) 实现的 DMM 资源代理，通过日本节点（TUN）绕过 DMM 的地区封锁 / 403，为客户端提供封面、剧照和预告片的直链访问与视频流式转发。

- Base URL: `http://{host}:{DMM_PROXY_PORT}`（默认 `8080`）
- 鉴权方式: `Authorization: Bearer <token>`（token 由环境变量 `DMM_AUTH_TOKEN` 指定）
- 默认 `DMM_PROXY_PORT=80`、`DMM_PROXY_SSL_PORT=443`，详见 `.env`

---

## 防护开关（`DMM_API_PROTECT`）

`DMM_API_PROTECT` 控制**代理侧**的防滥用保护（签名 URL、限流、IP 白名单），取值：`on`/`true`/`1`/`yes`（开启）或 `off`/空（关闭）。

> 注意：**`/api/*` 接口始终需要 `Authorization: Bearer <token>`**（无论 `DMM_API_PROTECT` 是 `on` 还是 `off`）。`/proxy/*` **不需要 token**；该开关只控制 `/proxy/*` 是否需要签名、限流与 IP 白名单。

| 开关 | `/api/*` | `/proxy/*` |
|------|----------|------------|
| **on**（默认，推荐生产） | 需要 `Authorization: Bearer <token>` | **无需 token**，需 `DMM_SIGN_TTL`（默认 220s）内有效的**签名 URL** + 限流 + 可选 IP 白名单 |
| **off** | 需要 `Authorization: Bearer <token>`，返回的 `proxy.*` 为普通路径 | **无需 token**、不要求签名、无限流/IP 白名单 |

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
| `401` | 缺少 Authorization 头（始终生效，`/api/*`） |
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

## 1.1 前端配置（config.js）

```
GET /config.js
```

无需鉴权。由 nginx Lua handler 动态生成，将 `DMM_AUTH_TOKEN` 环境变量注入为前端可用的 JavaScript 变量。

**响应 `200`**

```javascript
window.__API_TOKEN__ = 'your-dmm-auth-token-here';
```

| 响应头 | 值 |
|--------|-----|
| `Content-Type` | `application/javascript; charset=utf-8` |
| `Cache-Control` | `no-store` |

> 前端 `<script src="/config.js">` 加载后，通过 `window.__API_TOKEN__` 获取 token，调用 `/api/*` 时自动携带 `Authorization: Bearer <token>`。token 不会暴露在前端源码中。

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

根据番号返回预告片的多个码率直链与本机代理路径。仅返回探测存在的码率；探测顺序从最高档开始，且只探测最高三档（`hhb`/1080p、`hmb`/720p、`mhb`/480p），更低的 `dmb`/`dm`/`sm` 档不再返回。

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
    { "quality": "hmb", "bitrate": 3000, "url": "https://cc3001.dmm.co.jp/litevideo/freepv/s/ssi/ssis00497/ssis00497_hmb_w.mp4", "proxy": "/proxy/video/litevideo/freepv/s/ssi/ssis00497/ssis00497_hmb_w.mp4" },
    { "quality": "mhb", "bitrate": 2500, "url": "https://cc3001.dmm.co.jp/litevideo/freepv/s/ssi/ssis00497/ssis00497_mhb_w.mp4", "proxy": "/proxy/video/litevideo/freepv/s/ssi/ssis00497/ssis00497_mhb_w.mp4" }
  ]
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `id` | 用户传入的番号（大写） |
| `cid` | 探测命中的 DMM 内容 ID |
| `trailers[].quality` | 码率档位：`hhb`(5000k/1080p) / `hmb`(3000k/720p) / `mhb`(2500k/480p) |
| `trailers[].bitrate` | 码率（kbps） |
| `trailers[].url` | DMM 预告片直链 |
| `trailers[].proxy` | 本机代理路径（推荐使用，可避开地区封锁） |

> 极少数片子没有预告片，返回 `404`：
> ```json
> { "error": "not_found", "message": "Trailer not found for id: SONE-128" }
> ```

---

## 4.1 预告片直链（多源并发 + 缓存）

```
GET /api/trailer_direct/:id
```

按番号返回一个**可直接播放的预告片直链**（来自第三方源，非本机代理）。

**鉴权**：请求**始终需要** `Authorization: Bearer <token>`（与其它 `/api/*` 一致）。

**输入**：`:id` 为番号（如 `SNOS-213`）。服务端会**规范化**为全大写并去空白后作为缓存键与查询关键词；**不做格式校验**，任意字符串都接受，任何源都查不到才返回 `404`。

**流程**：

1. 先查内存缓存（`trailer_cache`，`lua_shared_dict`，键为 `td:<规范化番号>`），命中直接返回。
2. 未命中则**并发请求三个源**（AVWikiDB / DMM FANZA / JAVDatabase），谁先成功用谁的；单路超时 5 秒。
3. 命中后写入缓存（URL 与 source 各 7 天 TTL），并附带 `source` 字段。

> 注意：
> - 缓存为纯内存（`lua_shared_dict`），**容器重启会清空**，但重查一次即重新缓存 7 天。
> - **AVWikiDB 源**位于 Cloudflare 反爬（"Just a moment..." JS 挑战）之后，会拒绝数据中心/VPS IP，通常返回 `403`（详见代码注释）。正常主要由 **DMM FANZA** 与 **JAVDatabase** 两路提供结果。

**示例请求**

```http
GET http://localhost:8080/api/trailer_direct/SNOS-213
Authorization: Bearer <token>
```

**示例响应 `200`**

```json
{
  "code": "SNOS-213",
  "trailer": "https://cc3001.dmm.co.jp/pv/EDR4RCcjis11tGx2qP81rb6ZHD-bXv-mJM9oT8ultnH13mhCLb2MriUh1-SGjA/snos00213mhb.mp4",
  "source": "javdatabase"
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `code` | 规范化的番号（大写、去空格） |
| `trailer` | 可直连播放的预告片 URL（来自第三方源） |
| `source` | 命中的来源：`avwikidb` / `dmm` / `javdatabase` |

**错误码**

| 状态 | 场景 |
|------|------|
| `400` | 缺少番号 |
| `404` | 三个源均未找到预告片 |

`400` 示例（未带番号）：

```json
{ "error": "bad_request", "message": "Missing code" }
```

`404` 示例：

```json
{ "error": "not_found", "message": "No trailer found for code: ZZZ-99999" }
```

---

## 4.2 每日更新列表

```
GET /api/todayupdate
```

获取指定日期的 DMM 作品更新列表。不传 `date` 参数时默认获取**今日**（JST 时区）的数据。

通过 DMM FANZA GraphQL API（`https://api.video.dmm.co.jp/graphql`）查询按 `deliveryStartDate` 排序的最新作品。

**请求参数**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `date` | string | 否 | 日期，格式 `YYYY-MM-DD`，默认今日（JST） |
| `limit` | int | 否 | 每页数量，仅允许 `30` / `60` / `120`，默认 `30` |
| `offset` | int | 否 | 偏移量，用于分页，默认 `0` |

**示例请求**

```http
# 获取今日更新
GET http://localhost:8080/api/todayupdate
Authorization: Bearer <token>

# 获取指定日期，每页 120 条，第二页
GET http://localhost:8080/api/todayupdate?date=2026-09-03&limit=120&offset=120
Authorization: Bearer <token>
```

**示例响应 `200`**

```json
{
  "date": "2026-09-03",
  "total": 99,
  "limit": 30,
  "offset": 0,
  "hasNext": true,
  "count": 30,
  "works": [
    {
      "id": "1fns00241",
      "title": "雪国育ちの色白スレンダーBODYを性感開発する初イキッ3本番！ 柏木雫",
      "cover": {
        "medium": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/1fns00241/1fns00241ps.jpg",
        "large": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/1fns00241/1fns00241pl.jpg"
      },
      "deliveryStartAt": "2026-09-03T00:00:59+09:00",
      "actresses": [{ "id": "1112624", "name": "柏木雫" }],
      "maker": { "id": "40488", "name": "FALENO" },
      "isOnSale": true,
      "review": { "average": 5, "count": 1 },
      "releaseStatus": "LATEST_RELEASE",
      "price": {
        "productId": "1fns00241dl",
        "price": 2480,
        "discountPrice": null
      },
      "hasMultiplePrices": true,
      "sampleMovie": {
        "mp4": "https://cc3001.dmm.co.jp/pv/.../1fns002414k.mp4",
        "hls": "https://cc3001.dmm.co.jp/pv/.../playlist.m3u8"
      },
      "sampleImages": [
        { "number": 1, "largeUrl": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/1fns00241/1fns00241jp-1.jpg" },
        { "number": 2, "largeUrl": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/1fns00241/1fns00241jp-2.jpg" }
      ]
    }
  ]
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `date` | 查询的日期 |
| `total` | 该日期的总作品数 |
| `limit` | 当前分页大小 |
| `offset` | 当前偏移量 |
| `hasNext` | 是否有下一页 |
| `count` | 当前返回的作品数 |
| `works[].id` | DMM 产品 ID |
| `works[].title` | 作品标题 |
| `works[].cover.medium` | 中等尺寸封面直链 |
| `works[].cover.large` | 大尺寸封面直链 |
| `works[].deliveryStartAt` | 发布时间（ISO 8601，含时区） |
| `works[].actresses` | 演员列表 `[{id, name}]` |
| `works[].maker` | 制作商 `{id, name}` |
| `works[].isOnSale` | 是否在售 |
| `works[].review` | 评分 `{average, count}` |
| `works[].releaseStatus` | 发布状态（如 `LATEST_RELEASE`） |
| `works[].price` | 价格信息 `{productId, price, discountPrice}`，可能不存在 |
| `works[].hasMultiplePrices` | 是否有多种价格版本 |
| `works[].sampleMovie` | 预告片链接 `{mp4, hls}`，可能不存在 |
| `works[].sampleImages` | 剧照列表 `[{number, largeUrl}]`，可能不存在 |

**错误码**

| 状态码 | 场景 |
|--------|------|
| `502` | 上游 DMM GraphQL API 请求失败 |
| `400` | 缺少 Authorization 头 / token 无效 |

---

## 4.3 热门排行榜

```
GET /api/ranking
```

获取 DMM 热门作品排行榜，按销售排名分数（`SALES_RANK_SCORE`）排序。默认返回 30 条。

通过 DMM FANZA GraphQL API 查询，与每日更新使用相同的上游接口但排序方式不同。

**请求参数**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `limit` | int | 否 | 每页数量，仅允许 `30` / `60` / `120`，默认 `30` |
| `offset` | int | 否 | 偏移量，用于分页，默认 `0` |

**示例请求**

```http
# 默认热门 Top 30
GET http://localhost:8080/api/ranking
Authorization: Bearer <token>

# 第二页（第 31-60 名）
GET http://localhost:8080/api/ranking?limit=30&offset=30
Authorization: Bearer <token>

# 每页 120 条
GET http://localhost:8080/api/ranking?limit=120
Authorization: Bearer <token>
```

**示例响应 `200`**

```json
{
  "total": 478397,
  "limit": 30,
  "offset": 0,
  "hasNext": true,
  "count": 30,
  "works": [
    {
      "rank": 1,
      "id": "sqte00683",
      "title": "いつでも使えるオナホ後輩 花守夏歩",
      "cover": {
        "medium": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/sqte00683/sqte00683ps.jpg",
        "large": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/sqte00683/sqte00683pl.jpg"
      },
      "deliveryStartAt": "2026-05-16T00:00:00+09:00",
      "actresses": [{ "id": "1099813", "name": "花守夏歩" }],
      "maker": { "id": "45414", "name": "S-Cute" },
      "isOnSale": true,
      "review": { "average": 4.94, "count": 32 },
      "releaseStatus": "SEMI_NEW_RELEASE",
      "bookmarkCount": 31336,
      "price": {
        "productId": "sqte00683",
        "price": 580,
        "discountPrice": 290
      },
      "hasMultiplePrices": true,
      "sampleMovie": {
        "mp4": "https://cc3001.dmm.co.jp/pv/.../sqte00683hhb.mp4",
        "hls": "https://cc3001.dmm.co.jp/pv/.../playlist.m3u8"
      },
      "sampleImages": [
        { "number": 1, "largeUrl": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/sqte00683/sqte00683jp-1.jpg" }
      ]
    }
  ]
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `total` | 总作品数（排行榜全量） |
| `limit` | 当前分页大小 |
| `offset` | 当前偏移量 |
| `hasNext` | 是否有下一页 |
| `count` | 当前返回的作品数 |
| `works[].rank` | 排名（从 1 开始，基于 offset + 序号） |
| `works[].id` | DMM 产品 ID |
| `works[].title` | 作品标题 |
| `works[].cover.medium` | 中等尺寸封面直链 |
| `works[].cover.large` | 大尺寸封面直链 |
| `works[].deliveryStartAt` | 发布时间（ISO 8601，含时区） |
| `works[].actresses` | 演员列表 `[{id, name}]` |
| `works[].maker` | 制作商 `{id, name}` |
| `works[].isOnSale` | 是否在售 |
| `works[].review` | 评分 `{average, count}` |
| `works[].releaseStatus` | 发布状态 |
| `works[].bookmarkCount` | 收藏数（人气指标） |
| `works[].price` | 价格信息 `{productId, price, discountPrice}`，可能不存在 |
| `works[].hasMultiplePrices` | 是否有多种价格版本 |
| `works[].sampleMovie` | 预告片链接 `{mp4, hls}`，可能不存在 |
| `works[].sampleImages` | 剧照列表 `[{number, largeUrl}]`，可能不存在 |

**错误码**

| 状态码 | 场景 |
|--------|------|
| `502` | 上游 DMM GraphQL API 请求失败 |
| `400` | 缺少 Authorization 头 / token 无效 |

---

## 5. 封面图片代理

```
GET /proxy/aws/{path}
GET /proxy/pics/{path}
```

把 DMM 图片 CDN 的请求经本机（日本节点）转发，客户端直接可访问而不被 DMM 地区限制挡掉。通常由 `/api/cover` 返回的 `proxy.*` 路径使用。

**鉴权**：请求**无需携带 token**；`on` 时需有效签名 `?sig=&exp=`（`/api/cover` 返回时已附带），`off` 时直接访问。

| 代理路径 | 上游 CDN |
|----------|----------|
| `/proxy/aws/{path}` | `https://awsimgsrc.dmm.co.jp/pics_dig/{path}`（2K 高清封面） |
| `/proxy/sample/{path}` | `https://awsimgsrc.dmm.co.jp/dig_white/{path}`（高清剧照） |
| `/proxy/pics/{path}` | `https://pics.dmm.co.jp/{path}`（标准） |

- 访问 `/proxy/*` 时**无需携带 token**。
- `DMM_API_PROTECT=off` 时：直接使用 `/api/cover` 返回的原始 `proxy.*` 路径（无签名）。
- `DMM_API_PROTECT=on` 时：`/api/cover` 返回的 `proxy.*` 已自带 `?sig=&exp=`，直接使用即可；若去掉签名参数或已过期，返回 `403`。

**示例**（off 时的原始路径）

```http
GET /proxy/aws/digital/video/sone00128/sone00128pl.jpg

GET /proxy/pics/digital/video/sone00128/sone00128pl.jpg
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
- **无需携带 token**
- `DMM_API_PROTECT=on` 时，路径需带签名 `?sig=&exp=`（`/api/trailer` 返回时已附带），否则 `403`

**示例**（off 时的原始路径，on 时末尾追加 `?sig=&exp=`）

```http
GET /proxy/video/litevideo/freepv/s/ssi/ssis00497/ssis00497_mhb_w.mp4
```

响应 `Content-Type: video/mp4`，支持 `Range`（返回 `206 Partial Content`）。

---

## 鉴权失败响应

```json
{ "error": "unauthorized", "message": "Missing Authorization header. Use: Authorization: Bearer <token>" }   // 401
{ "error": "forbidden", "message": "Invalid token" }                                                         // 403
```

---

## 前端界面

访问 `http://localhost:80` 打开内置 SPA 浏览界面。前端通过 `/config.js` 获取 token 后自动调用 `/api/todayupdate` 和 `/api/ranking` 接口获取数据。

### 功能

- **今日更新**：7 天时间线选择器 + 卡片网格浏览
- **热门排行**：销量排名展示，含排名序号与收藏数
- **图片预览**：点击卡片弹出大图弹窗，封面 + 剧照轮播，键盘 `←` `→` / `Esc` 导航
- **配色主题**：6 套小清新风格一键切换（薄荷绿 / 樱花粉 / 薰衣草 / 海洋蓝 / 暖杏色 / 夜猫黑）
- **中英双语**：界面语言一键切换
- **Mock 降级**：API 不可用时自动使用内置 mock 数据

### 前端调用的接口

| 接口 | 用途 | 鉴权 |
|------|------|------|
| `GET /config.js` | 获取 API token | 无需 |
| `GET /api/todayupdate?date=YYYY-MM-DD&offset=0&limit=30` | 今日更新列表 | `Bearer <token>` |
| `GET /api/ranking?offset=0&limit=30` | 热门排行榜 | `Bearer <token>` |

### 字段映射（API → 前端）

| API 字段 | 前端用途 |
|----------|----------|
| `cover.medium / cover.large` | 卡片封面图 |
| `sampleImages[].largeUrl` | 弹窗图片列表（封面 + 全部剧照） |
| `price.price / price.discountPrice` | 卡片价格显示（円） |
| `actresses[].name` | 卡片演员标签 |
| `maker.name` | 卡片商家标签 |
| `bookmarkCount` | 排行榜收藏数（♥ N） |
| `rank` (offset + i) | 排行榜排名（#N） |
| `hasNext / total / offset / limit` | 分页控制 |
