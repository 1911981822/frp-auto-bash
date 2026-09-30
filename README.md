# frp-auto-bash

frp 的一键部署外壳：一条命令装好 frps / frpc，之后**所有隧道都在浏览器里增删改，即时生效，不重启进程**。

基于 [fatedier/frp](https://github.com/fatedier/frp) v0.71.0 的原生能力（内置 Web 管理端 + Store 动态代理）构建，不改动、不重新实现 frp 本身。

## 30 秒上手

**云服务器（装服务端）**

```bash
curl -fsSL https://raw.githubusercontent.com/1911981822/frp-auto-bash/main/install.sh | sudo bash -s -- server
```

**内网小主机（装客户端）**

```bash
curl -fsSL https://raw.githubusercontent.com/1911981822/frp-auto-bash/main/install.sh | sudo bash -s -- client \
    --server-addr <公网IP> --server-port 7000 --token <上面的token> --ssh-remote-port 20001
```

装完即可 `ssh -p 20001 <用户名>@<公网IP>`。

**之后新增任何隧道（无需重启、无需改配置）**

```bash
frp-easy add web --type tcp --local-port 8080 --remote-port 20010
frp-easy status
frp-easy del web
```

## 命令一览

| 命令 | 作用 |
|------|------|
| `install.sh server` | 安装 frps（交互式配置端口、token、端口池） |
| `install.sh client` | 安装 frpc（自动生成 SSH 穿透 + 管理端 + Store） |
| `install.sh uninstall` | 卸载（保留配置与隧道库） |
| `frp-easy status` / `list` | 查看服务与隧道状态（表格化） |
| `frp-easy add <名> [选项]` | 动态新增隧道，即时生效并持久化 |
| `frp-easy del <名>` | 删除隧道，即时生效 |
| `frp-easy expose-admin` | 生成管理端访问通道（stcp 私有隧道） |
| `frp-easy backup` / `restore` | 配置与隧道库备份 / 回滚 |
| `frp-easy update [版本]` | 升级 frp |
| `frp-easy doctor` | 健康自检 |
| `frp-easy rescue` | 配置写错导致失联时的一键回滚 |

### `add` 选项

| 选项 | 说明 |
|------|------|
| `--type` | `tcp` / `udp` / `http` / `https` / `stcp`，默认 tcp |
| `--local-ip` | 本机服务地址，默认 127.0.0.1 |
| `--local-port` | 本机服务端口（必填） |
| `--remote-port` | 公网端口（tcp/udp 必填，须在服务端 `allowPorts` 池内） |
| `--domain` | http/https 用域名；stcp 用此传 secretKey |

```bash
frp-easy add blog --type http --local-port 4000 --domain blog.example.com
```

## 设计要点

**1. 配置分层，永远不必重启**

```
frpc.toml   → 基础连接 + 管理端 + 自举通道（脚本生成，几乎不改）
db.json     → 所有业务隧道（浏览器/frp-easy 动态增删改，即时生效）
```

`frpc reload` 无法修改公共段（serverAddr / auth / transport），所以把"不变的部分"和"常变的部分"分开。改隧道走 Store，连 reload 都不需要。

**2. 管理端不上公网**

管理端强制监听 `127.0.0.1`，通过安装时预置的 `stcp` 私有隧道（`admin-panel`）带出。管理端不占用公网端口、不被端口扫描。
访问时在你自己的电脑上跑一个 visitor：

```bash
frp-easy expose-admin     # 生成配置
frpc -c /var/lib/frp/admin-visitor.toml
# 浏览器打开 http://127.0.0.1:17400
```

**3. 自举与救援**

管理端要靠 frp 才能出公网，而 frp 配置又靠管理端来改——这是自举问题。因此：
- 安装时固定写入 `admin-panel` 自举通道；
- 服务端默认开启 `sshTunnelGateway`（2200），即使 frpc 配置写错也能 `ssh -R` 临时建隧道救回；
- `frp-easy rescue` 可从历史备份一键回滚，并在回滚后自动 `verify`。

## 目录布局

```
/usr/local/bin/frps, frpc, frp-easy
/etc/frp/frps.toml | frpc.toml         # 配置（750，root:frp）
/etc/frp/.frp-easy.env                 # 安装参数（600）
/var/lib/frp/db.json                   # 动态隧道库（Store）
/var/lib/frp/backups/                  # 备份
/etc/systemd/system/frps.service | frpc.service
```

## 安全基线

- token 随机生成（32 位），长度不足 16 时 `doctor` 会告警
- 管理端 BasicAuth 随机强口令，强制 `127.0.0.1` 监听；`doctor` 检测到 `0.0.0.0` 会告警
- 服务端 `allowPorts` 收敛端口池，防止客户端乱占端口
- 以非 root 用户 `frp` 运行，systemd 启用 `ProtectSystem=strict` + `ReadWritePaths`
- 下载时强制 SHA256 校验，不匹配立即中止
- 建议小主机 SSH 关闭密码登录、仅用密钥

## 已知坑（重要）

1. **手写 frpc.toml 时，公共配置必须写在 `[[proxies]]` 之前。** TOML 中 `[[proxies]]` 之后的键值对会被解析为该代理的字段，例如把 `log.level` 写在末尾会报 `unknown field "log"`。本项目模板已处理，自行修改时请注意。
2. **Store API 的 JSON 必须带类型子块**：`{"name":"x","type":"tcp","localIP":"..","localPort":N,"tcp":{"remotePort":N}}`，平铺字段会返回 `400 exactly one proxy type block is required`。
3. **INI 格式已弃用**，本仓库只生成 TOML。
4. frp 目前是 v0.x，官方计划 v2 做不兼容重构，脚本默认锁定 v0.71.0。

## 测试模式

不想污染系统目录时用 `FRP_ROOT` 重定向（不创建用户、不操作 systemd）：

```bash
FRP_ROOT=/tmp/frp-test ./install.sh server -y --no-service --bind-port 17000
FRP_ROOT=/tmp/frp-test ./install.sh client -y --no-service \
    --server-addr 127.0.0.1 --server-port 17000 --token xxx --ssh-remote-port 16000
```

## 发布前必改

`install.sh` 与 `bin/frp-easy` 中的仓库地址占位符：

```bash
: "${FRP_EASY_REPO:=1911981822/frp-auto-bash}"
```

改成你自己的 `owner/repo`，否则远程执行与 `update` 无法工作。

## License

MIT
