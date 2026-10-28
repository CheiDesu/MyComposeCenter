# Compose 一键备份 / 恢复中心（ccenter）

一个跑在 Docker 宿主机上的交互式脚本：**发现 → 备份 → 查看/删除 → 恢复 → 自动备份**，全程数字菜单。只用宿主已有的 `bash / docker compose / tar / zstd(gzip) / jq / flock / sha256sum`，不需要装任何额外依赖。

- 脚本：`ccenter.sh`（单文件，约 1100 行 bash，无外部依赖）
- 备份根目录：**默认 = 脚本所在文件夹**，可在「配置」里改
- 不碰 Docker 守护进程、不删镜像、不删卷；破坏性动作都要二次确认

---

## 1. 快速开始（克隆即用，不需要改任何个人信息）

```bash
git clone https://github.com/CheiDesu/MyComposeCenter.git
cd MyComposeCenter
sudo bash ccenter.sh
```

首次运行会自动做三件事：

1. 在脚本目录生成 **`config.ini`** —— 每个配置项都带中文注释，默认值对绝大多数机器直接可用；
2. 检查依赖（`tar jq flock sha256sum` + `zstd` 或 `gzip`），缺什么会直接告诉你怎么装；
3. 进入主菜单。

> 脚本里**没有任何硬编码的主机名、IP、账号、容器名或项目名**。你的机器信息只存在于运行时生成的 `config.ini` 里，而 `config.ini` 已被 `.gitignore` 排除，不会被提交。

也可以放到固定目录并加命令：

```bash
sudo mkdir -p /opt/ccenter
sudo cp ccenter.sh /opt/ccenter/
sudo chmod +x /opt/ccenter/ccenter.sh
sudo ln -sf /opt/ccenter/ccenter.sh /usr/local/bin/ccenter
sudo ccenter
```

> ⚠️ 必须用 **bash** 运行（`bash ccenter.sh` 或 `./ccenter.sh`，脚本首行是 `#!/usr/bin/env bash`）；用 `sh ccenter.sh` 会报 `set: Illegal option -o pipefail`。

## 2. 交互用法

直接运行（无参数）：

```bash
sudo ccenter
```

主菜单：

```
1) 备份快照          2) 查看 / 删除备份
3) 一键恢复          4) 配置
5) 状态与日志        6) 校验 / 导出
q) 退出
```

- **1) 备份快照**：列出宿主所有 compose 项目（编号/项目/状态/服务数/compose 路径/数据量/最近文件时间），输入编号选择（支持 `1`、`1,3`、`1-3`）。
  备份前可选：在线（不停机）/ 静止（停机打包，推荐有状态项目）；是否包含 bind 挂载目录；是否包含镜像本体。
  打包过程有**进度条**（终端里是 `████░░░░` + 百分比，重定向到文件时退化成 `[3/6] 卷 xxx` 行）。
- **2) 查看 / 删除备份**：列表带编号，并直接标出每份快照 **是否含 bind 目录/镜像**（`bind`、`镜像` 两列，`有 N` 表示 N 个）；`d` 删除（y/n 确认）；最新一份默认受保护。表格按中文显示宽度对齐。
- **3) 一键恢复**：选编号 → 显示快照详情（compose 文件数 / 命名卷数 / bind 数 / 镜像）→ 输入 `y` 回车确认 → 先自动打「恢复前快照」→ 还原 compose/卷/bind → 按需 `docker load` 导入镜像 → 拉起容器 → 健康检查；失败自动回滚。恢复过程同样有进度条，每次恢复只保留最新一份 `.pre-restore` 备份（不会越堆越多）。
  > 想让恢复连**会话历史**一起回来（例如 DSH 的 `/root/.dsh` 在 bind 目录里），备份时要带上 bind（`--bind` 或配置 `include_bind=1` / `bind_projects`），否则快照里只有 compose 与命名卷。
- **4) 配置**：菜单里逐项修改，保存后自动写回带注释的 `config.ini`；也能安装/卸载定时器。
- **5) 状态与日志**：docker/compose 版本、根目录、占用、快照数、最近日志。
- **6) 校验 / 导出**：对快照做 sha256 与 tar 完整性校验，可导出到别处（U 盘/另一台 NAS）。

## 3. 命令行（可写进定时器）

```bash
ccenter projects                 # 列出可备份项目（TSV）
ccenter backup <项目> [--quiesce] [--bind] [--images]
ccenter list
ccenter restore --id <id> [--skip-pre] [--yes]
ccenter delete <id> [--yes]
ccenter prune                    # 按容量策略清理
ccenter verify [<id>]            # 省略则校验全部
ccenter export --id <id> --dest <目录>
ccenter status [--json]
ccenter auto                     # 自动备份一轮（定时器调用这个）
ccenter config [--json]
ccenter timer install            # 安装定时器（等价于配置菜单第 13 项）
ccenter timer uninstall
```

## 4. 目录结构

```
<备份根>/                 ← 默认 = 脚本所在目录
├── config.ini            ← 配置（每个键都有注释，可直接编辑）
├── index.json            ← 快照索引
├── logs/                 ← 运行日志
├── export/               ← 导出目录（export_target 留空时用这里）
└── snapshots/
    ├── <项目>_<YYYYmmdd-HHMMSS>_<online|quiesced>.tar.zst
    ├── ...manifest.json  ← 清单（compose 文件/卷/镜像 digest 与 sha256）
    └── ....sha256        ← 包校验和
```

## 5. 配置项说明（`config.ini`）

首次运行自动生成，每一项前面都有注释；下面是完整说明。

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `root` | 脚本所在目录 | 备份根目录：快照、索引、日志都放这里。想放到独立磁盘就改这里。 |
| `auto_enabled` | `1` | 自动备份开关：`1` 开，`0` 关（只影响定时任务，手动备份不受影响）。 |
| `auto_interval` | `12` | 自动备份间隔，单位小时。 |
| `max_size` | `10G` | 快照总容量上限，支持 `K/M/G/T`；超过后从最旧开始删。 |
| `min_keep` | `2` | 无论容量是否超限，至少保留几份。 |
| `compress` | `zstd` | 压缩方式：`zstd`（推荐）或 `gzip`（没有 zstd 时用）。 |
| `consistency` | `online` | `online` 不停容器（快）；`quiesced` 备份前短暂停容器（一致性好，会中断几秒）；`ask` 每次询问。 |
| `include_bind` | `0` | 是否把 bind mount 的本地目录也打进快照：`0` 不（默认），`1` 是（整机还原必需，例如 DSH 的会话在 bind 目录里）。 |
| `bind_projects` | `dsh-compose` | 自动备份时，即使 `include_bind=0`，也强制打包这些项目的 bind（逗号分隔）。想让自动备份包含会话历史就填项目名；不需要就留空。 |
| `include_images` | `0` | 是否用 `docker save` 把镜像也存进快照：`0` 不，`1` 是（每份多几百 MB~GB）。 |
| `auto_projects` | `all` | 自动备份包含哪些项目：`all` 或逗号分隔的项目名（如 `blog,db`）。 |
| `retention` | `recent` | `recent` 超限删最旧；`daily` 每个项目每天只保留最新一份。 |
| `export_target` | 空 | 「校验/导出」的默认导出目录；留空 = `<root>/export`。 |

容量策略：超过 `max_size` 时从最旧开始删，**永远保留最新 `min_keep` 份**。

自动备份定时器（配置菜单第 13 项，或 `ccenter timer install`）：

```bash
systemctl list-timers | grep ccenter               # 查看下次触发
journalctl -u ccenter-backup.service -n 50         # 看跑批输出
sudo systemctl disable --now ccenter-backup.timer  # 临时关闭（或 ccenter timer uninstall 彻底卸载）
```

定时器 = systemd `OnBootSec=10min` + `OnUnitActiveSec=<auto_interval>h` + `Persistent=true`（关机期间错过的会在开机后补跑一次）。

## 6. 安全说明

- 备份只读：只跑 `docker compose ps/config`、`docker inspect`、命名卷只读打包；`quiesced` 模式会短暂 `stop` 再 `start` 项目容器。
- 恢复写操作：只在目标项目工作目录内还原 compose 文件，命名卷先备份旧内容再覆盖；每次恢复前自动生成「恢复前快照」。
- 自己恢复自己：若恢复的项目就是当前 DSH 所在 compose，界面会提示并**转入后台执行**（`setsid nohup`），不会把当前会话打断在半路。
- 权限：脚本需要 root（读 `/var/run/docker.sock`、写 `/etc/systemd/system`）；快照文件权限固定 `644`。

## 7. 已验证（sandbox 实测，不涉及生产 compose）

| 场景 | 结果 |
| --- | --- |
| 项目发现 | 正确识别 compose 项目、运行状态与 compose 文件路径 |
| 在线备份 | 沙箱 nginx 项目：5.1 KB · 1 秒 |
| 静止备份 | 停 → 打包卷 → 启，4.9 KB · 2 秒 |
| 恢复（含卷） | 卷内文件回滚成功，容器恢复 Up |
| 删除 / prune | 删除旧快照、超限自动清理最旧并保留最新 |
| 校验 / 导出 | sha256 与 tar 完整性通过，导出文件 644 可读 |
| auto 批量 | 按 auto_projects 过滤，逐个项目执行 |

## 8. 已知限制

- `docker compose ls` 只列 compose v2 项目；纯 `docker run` 的容器不会被发现。
- 大卷备份耗时与体积取决于数据量；建议 `max_size` 与磁盘余量按实际调整。
- 无远程仓库功能（当前只做本地/挂载目录导出）；需要异地可配 `export_target` 或后续扩展 rsync。

## 9. License

MIT
