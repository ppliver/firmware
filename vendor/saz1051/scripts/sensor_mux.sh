#!/bin/sh
# SAZ1051 sensor muxer / clock bring-up (devmem 版)
# 复刻原厂 swapp 时序 (_comm_muxer_with_sensor / _comm_muxer_with_i2c / _comm_sns_clock_enable)
#
# 历史坑: 原先用 /opt/tools/sazreg.ko, 但该模块编译成了 [permanent]
#   (lsmod: "sazreg 16384 0 [permanent]" / rmmod: "Resource busy"),
#   而脚本是 "每条寄存器 rmmod->insmod->rmmod" 的写法 —— 只有第 1 条能插进去,
#   之后全部 "can't insert: File exists", 且关键的最后一条 clock enable 从未写入,
#   导致 /proc/umap/mipi_rx 里 sensor_clk 恒为 N -> MIPI 无数据 -> VI 无帧 -> 出图失败。
# 现改用 busybox devmem 直写物理寄存器, 无模块加载/卸载问题, 5 条全部生效。
#
# 寄存器依据 (原厂 swapp 日志):
#   sensor_clk    reg:0x17940040 = 0x1212
#   sensor_rstn   reg:0x17940050 = 0x1137
#   i2c0 sda      reg:0x17940098 = 0x1135
#   i2c0 scl      reg:0x1794009c = 0x1135
#   clock enable  reg:0x11018440 = 0xa010
DM=/sbin/devmem

wr() { $DM "$1" 32 "$2"; }

wr 0x17940040 0x1212    # sensor0 clk pad
wr 0x17940050 0x1137    # sensor0 rstn pad
wr 0x17940098 0x1135    # i2c0 sda
wr 0x1794009c 0x1135    # i2c0 scl
wr 0x11018440 0xa010    # sensor clock enable

echo "[sensor_mux] muxer/clock applied: clk=$($DM 0x17940040 32) rstn=$($DM 0x17940050 32) clken=$($DM 0x11018440 32)"
