# Ubuntu 24.04 IBus/LibPinyin 输入法迁移

中文 | [English](README.md)

这是一个谨慎、可回滚的迁移工具，用于在两台 Ubuntu 24.04 GNOME 机器之间
迁移 IBus/LibPinyin（智能拼音）配置。

可迁移内容：

- GNOME 输入源和输入源切换快捷键
- IBus 与 LibPinyin 的 dconf 设置
- LibPinyin 已学习的词频、短语和用户词库
- 当前用户的输入法选择器
- 软件包清单；目标机只安装缺失的软件包

项目也解决了实机迁移中遇到的典型冲突：即使 `im-config` 已选择 IBus，
Fcitx5 仍可能在登录时自动启动并占用 IBus 的 D-Bus 名称。导入时会先备份，
再禁用用户级 Fcitx5 自动启动项，并移除 `~/.pam_environment` 中强制使用
Fcitx5 的环境变量。

## 使用条件

- Ubuntu 24.04 GNOME
- 以当前桌面用户运行，**不要**用 `sudo` 运行整个脚本
- 源机器已安装 `ibus-libpinyin`

仅当目标机缺少必要软件包时，脚本才会调用 `sudo`。

## 快速使用

在源机器执行：

```bash
chmod +x input-method-migrate.sh
./input-method-migrate.sh export
```

把脚本和生成的 `.tar.gz` 迁移包复制到目标机。先检查，再导入：

```bash
./input-method-migrate.sh inspect ./ubuntu24-input-method-*.tar.gz
./input-method-migrate.sh import ./ubuntu24-input-method-*.tar.gz
```

注销并重新登录一次，然后验收：

```bash
./input-method-migrate.sh check
```

使用 **Super+Space** 切换输入源。

## 备份与回滚

每次导入都会自动备份目标机原配置：

```text
~/.local/state/input-method-migrate/backups/
```

查看及恢复备份：

```bash
./input-method-migrate.sh list-backups
./input-method-migrate.sh rollback /before-import/备份目录的绝对路径
```

执行回滚前，脚本还会再保存一份当前状态。

## 安全设计

- 只导入自己生成或确认可信的迁移包
- 使用 SHA-256 校验迁移包内容
- 解压前检查归档路径
- 替换目标机数据前自动备份
- 校验软件包名，且仅安装缺失的软件包

## 不会迁移的内容

- IBus 运行时 socket
- 可自动重建的注册表缓存
- 系统级配置
- 密码、密钥或其他无关桌面设置

## 故障排查

如果 `check` 提示 Fcitx5 占用了 IBus，请检查：

```bash
~/.config/autostart/fcitx5.desktop
~/.pam_environment
```

导入器通常会自动备份并处理这两项。由于桌面程序在登录时继承输入法环境变量，
完成导入后必须注销并重新登录一次。

## 许可证

MIT
