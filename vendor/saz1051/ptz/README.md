# SAZ1051 PTZ (云台) — OpenIPC 移植说明

## 硬件 / 驱动
- 电机驱动：`motor_mx2208a.ko`（MiXic MX2208A 步进驱动，misc 设备名 `swmotor`
  → 用户态节点 `/dev/swmotor`）。vermagic `5.10.221`，与 OpenIPC 运行内核 ABI 一致。
- 控制方式：模块内 `mx2208a_i2c_send` 用 **GPIO 位拍 I2C** 发命令给 MX2208A，
  不是硬件 I2C 控制器；步进节拍用 `vendor,timer23`（irq 49）。
- 默认 GPIO：`en=63 / data=13 / clk=12 / rst=8`，`m_timer_counts=3000`
  （从 `.ko` 的 `.data` 段解出 + 实况 `insmod` 复现验证）。

## 打包 / 加载
- ko 安装到 `/lib/modules/5.10.221/motor_mx2208a.ko`，由 `S45saz_motor`
  （`/etc/init.d/`）在开机早期裸 `insmod`（用内置默认值），`mdev -s` 生成 `/dev/swmotor`。
- 用户态工具：`/usr/bin/swmotor_ctl`（源码 `swmotor_ctl.c`，随 `saz1051-vendor`
  用 `$(TARGET_CC)` 编译）。
- Web 控制面：`/var/www/cgi-bin/ptz.cgi`（haserl），访问 `/cgi-bin/ptz.cgi`。

## ⚠️ 方向映射是"假设"，必须在真机验证
驱动是 **stripped** 闭源二进制，其 `ioctl cmd → 方向` 的语义**无法静态确定**。
已确认的只有：
- 驱动接受的 ioctl cmd ∈ **{0, 3, 4, 5, 6, 7, 8}**
- **cmd 0 = 复位 / 停止运行态**（tbh 跳转表里 cmd0 即 stop/reset 分支）
- cmd 1、2 被拒绝（打印 `not support cmd`）
- cmd 3/4/5/6/7/8 是各种移动 / 步进变体

`swmotor_ctl` 内置默认映射是**猜测**：`left=3 right=4 up=5 down=6 stop=0 reset=0`。
原厂 `motor.json` 的应用层方向码（TurnLeft=1/Right=2/Up=3/Down=4）**不等于**
驱动 ioctl cmd——二者之间原厂 `swapp` 有一张转换表，本 README 未做字节级验证。

### 真机探测步骤（刷好固件后）
1. 确认节点存在：`ls -l /dev/swmotor`（没有则查 `dmesg | grep swmotor` / `MX2208A`）。
2. 逐一试 cmd，观察电机实际转向：
   ```
   for c in 3 4 5 6 7 8; do
     echo "=== cmd $c ==="; swmotor_ctl raw $c 100; sleep 1; swmotor_ctl stop; sleep 1
   done
   ```
3. 把正确的 cmd 写进 `/etc/swmotor.map`（每行 `<方向> <cmd>`，例：`left 5`），
   重启或重新打开 WebUI 即生效。
4. 如果 `raw` 某些 cmd 报 `Not a typewriter` / `Invalid argument`，说明该 cmd 需要
   不同参数格式——先以 `arg=0` 重试，再配合步数参数排查。

> 注：本板出厂无位置记忆持久化需求；预置位 / 巡航若需要，参考原厂
> `/data/.swdb/ptz_scan.json` 与 `motor.json` 的几何参数（水平 360° / 垂直 110° / Step=10）。
