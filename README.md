# Compose 一键备份 / 恢复中心（ccenter）

一个跑在 Docker 宿主机上的交互式脚本：**发现 → 备份 → 查看/删除 → 恢复 → 自动备份**，全程数字菜单，零依赖（只用宿主已有的 `bash / docker compose / tar / zstd(gzip) / jq / flock / sha256sum`）。

- 脚本：`ccenter.sh`（单文件，约 1100 行 bash）
- 备份根目录：**默认 = 脚本所在文件夹**，可在「配置」里改
- 不碰 Docker 守护进程、不删镜像、不删卷；所有破坏性动作都要二次确认

---

## 1. 安装

把 `ccenter.sh` 放到任意目录（建议单独一个目录），`chmod +x` 即可：

```bash
sudo mkdir -p /opt/ccenter
sudo cp ccenter.sh /opt/ccenter/
sudo chmod +x /opt/ccenter/ccenter.sh
sudo ln -sf /opt/ccenter/ccenter.sh /usr/local/bin/ccenter
```

> ⚠️ 必须用 **bash** 运行（`bash ccenter.sh`）；用 `sh` 会报 `set: Illegal option -o pipefail`。

依赖检查：`tar zstd gzip jq flock sha256sum docker compose`。缺 `zstd` 时自动回落 gzip。

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
- **2) 查看 / 删除备份**：列表带编号，`d` 删除（y/n 确认）；最新一份默认受保护。
- **3) 一键恢复**：选编号 → 确认 → 先自动打「恢复前快照」→ 还原文件与命名卷 → 拉起容器 → 健康检查；失败自动回滚。
- **4) 配置**：备份根目录、自动备份开关、间隔、容量上限、保留份数、压缩方式、一致性默认值、自动备份范围、保留策略、导出目标、定时器安装/卸载。
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
```

## 4. 目录结构与配置

```
<备份根>/                 ← 默认 = 脚本所在目录
├── config.ini            ← 配置（可直接编辑）
├── index.json            ← 快照索引
├── logs/                 ← 运行日志
└── snapshots/
    ├── <项目>_<YYYYmmdd-HHMMSS>_<online|quiesced>.tar.zst
    ├── ...manifest.json  ← 清单（compose 文件/卷/镜像 digest 与 sha256）
    └── ....sha256        ← 包校验和
```

`config.ini` 键：`root / auto_enabled / auto_interval / max_size / min_keep / compress / consistency / include_bind / include_images / auto_projects / retention / export_target`。

容量策略：超过 `max_size` 时从最旧开始删，**永远保留最新 `min_keep` 份**；`retention=recent` 为默认，可切 `daily`（按天保留一份）。

自动备份定时器（配置菜单第 13 项）：

```bash
sudo systemctl enable --now ccenter-backup.timer   # 首次 OnBootSec 5min、之后每 auto_interval 小时
systemctl list-timers | grep ccenter               # 查看
journalctl -u ccenter-backup.service -n 50         # 看跑批输出
```

## 5. 安全说明

- 备份只读：`docker compose ps/config`、`docker inspect`、命名卷只读打包；静止模式会短暂 `stop` 再 `start` 项目容器。
- 恢复写操作：只在目标项目工作目录内还原 compose 文件，命名卷先备份旧内容再覆盖；每次恢复前自动生成「恢复前快照」。
- 名称冲突：同项目同聊天（卷/文件）重复备份会被索引去重逻辑拦下。
- 自己恢复自己：若恢复的项目就是当前 DSH 所在 compose，界面会提示并**转入后台执行**（`setsid nohup`），不会把当前会话打断在半路。

## 6. 已验证（本机 sandbox 实测，不涉及生产 compose）

| 场景 | 结果 |
| --- | --- |
| 项目发现 | 正确识别 compose 项目、运行状态与 compose 文件路径 |
| 在线备份 | 沙箱 nginx 项目：5.1 KB · 1 秒 |
| 静止备份 | 停 → 打包卷 → 启，4.9 KB · 2 秒 |
| 恢复（含卷） | 卷内文件回滚成功，容器恢复 Up |
| 删除 / prune | 删除旧快照、超限自动清理最旧并保留最新 |
| 校验 / 导出 | sha256 与 tar 完整性通过，导出可读 |
| auto 批量 | 按 auto_projects 过滤，逐个项目执行 |

## 7. 已知限制

- `docker compose ls` 只列 compose v2 项目；纯 `docker run` 的容器不会被发现。
- 大卷备份耗时与体积取决于数据量；建议 `max_size` 与磁盘余量按实际调整。
- 无远程仓库功能（当前只做本地/挂载目录导出）；需要异地可配 `export_target` 或后续扩展 rsync。
