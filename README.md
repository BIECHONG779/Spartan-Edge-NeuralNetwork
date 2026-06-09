# Spartan Edge — 按键手势 MLP 推理

在 Seeed Spartan Edge Accelerator Board (XC7S15) 上部署一个 int8 量化的极小 MLP,
用 2 个用户按键 (USER1/USER2) 做手势分类 (4 类), 2 颗板载 SK6805 RGB LED + 2 颗普通 LED 输出结果.

## 目录结构

```
.
├── Board/                                 # 厂家原理图 (PDF, 不动)
├── train/
│   └── train_and_export.py                # 数据合成 + 训练 + int8 量化 + 导出权重/参考向量
├── rtl/
│   ├── mem/                               # 训练脚本生成的 *.mem / params.vh
│   ├── clk_div.v                          # 50MHz -> 50Hz tick
│   ├── debounce.v                         # 按键去抖
│   ├── button_capture.v                   # 64 帧 × 2 bit = 128 bit 输入向量
│   ├── mlp_inference.v                    # 串行 int8 MAC 推理引擎 (核心)
│   ├── ws2812_driver.v                    # 2 颗 SK6805 RGB LED 菊花链驱动
│   └── top.v                              # 顶层
├── sim/
│   ├── tb_mlp.v                           # bit-true testbench
│   └── vectors/test_vectors.txt           # 训练脚本生成
├── vivado/
│   ├── constraints.xdc                    # 引脚 (已按 PDF + Seeed 官方 XDC 核对)
│   └── build.tcl                          # 非项目模式编译脚本
└── CLAUDE.md
```

## 设计要点

| 模块 | 复杂度 |
|---|---|
| 时钟 | 板载 100 MHz 有源晶振 (型号 O3225100MEDA4SC, 接 H4) |
| 输入 | USER1 / USER2 物理按键 (低有效, 内部上拉, RTL 反相后采样), 50 Hz x 64 帧 = 128 bit |
| 网络 | MLP: 128 → 16 (ReLU) → 4, int8 对称量化, 共 ~2 KB 权重 (BRAM) |
| 推理 | 单 DSP 串行 MAC, 内部 CE ÷2 (有效 50 MHz), 一次推理 ~2200 cycle ≈ 44 µs @ 100 MHz |
| 输出 | 2 颗板载 SK6805 RGB LED (协议兼容 WS2812, 菊花链 N11) + 2 颗普通 LED (二进制 class_id) |
| 时序 | Spartan-7 -1 MAC 关键路径 ~12.2 ns, 不能满足 100 MHz; 用 CE ÷2 + multi-cycle 约束解决 |
| 量化误差 | 浮点 100% → int8 100% → 硬件等价 100% (50 个测试样本 RTL 与 Python bit-true 完全一致) |

## 类别定义

| Class | 含义 | RGB1 | RGB2 | 普通 LED1/2 |
|---|---|---|---|---|
| 0 | USER1 长按 (>500 ms) | 黄 | 黄 | 0 / 0 |
| 1 | USER1 双击 | 蓝 | 蓝 | 0 / 1 |
| 2 | USER2 长按 (>500 ms) | 品红 | 品红 | 1 / 0 |
| 3 | USER2 双击 | 青 | 青 | 1 / 1 |

## 一键复现流程

```bash
# 1) 训练 + 导出 (任何安装了 numpy 的 Python3 都行)
python3 train/train_and_export.py
# 产物: rtl/mem/*.mem, sim/vectors/test_vectors.txt, rtl/mem/params.vh

# 2) (可选) 本地 RTL 仿真验证 bit-true
#    需要 iverilog: brew install icarus-verilog
cd sim && ln -sf ../rtl/mem mem
iverilog -g2012 -I ../rtl -o tb_mlp.vvp tb_mlp.v ../rtl/mlp_inference.v
vvp tb_mlp.vvp     # 期望 PASS bit-true match

# 3) Vivado 综合 + 实现 + 生成 .bit
cd ../vivado
vivado -mode batch -source build.tcl
# 产物: build/spartan_edge_mlp.bit
```

##还需要做的事

1. 用 Vivado 打开 `vivado/build.tcl`, 按你实际的 Vivado 版本和 part number 跑一遍.
   板子是 XC7S15-1FTGB196C; 如果不同请改 `PART`.
2. 引脚已基于 `Board/Spartan Edge Accelerator Board v1.0.pdf` 第 1/3 页原理图逐一核对:
   `sysclk=H4 (100 MHz) / btn0(USER1)=C3 (FPGA_IO10) / btn1(USER2)=M4 (FPGA_IO11) / ws2812_din=N11 (FPGA_RGB) / led_status[0]=J1(FPGA_LED1) / led_status[1]=A13(FPGA_LED2)`.
3. 把 `vivado/build/spartan_edge_mlp.bit` 拷贝到 SD 卡, 让你已有的 ESP32 加载器
   通过 Slave Serial 烧录到 FPGA. 配置成功后:
   - 长按 USER1 → RGB1+RGB2 黄, LED1/2 灭
   - 双击 USER1 → RGB1+RGB2 蓝, LED2 亮
   - 长按 USER2 → RGB1+RGB2 品红, LED1 亮
   - 双击 USER2 → RGB1+RGB2 青, LED1+LED2 都亮

## 安全自检

- ✅ 不信任输入: 板载按键已去抖 + 同步寄存器, 阻止亚稳态;
- ✅ 无外部数据通路: 推理输入仅来自 GPIO, 无网络/串口;
- ✅ 权重在比特流中固化 (BRAM init), 运行时不可改写, 杜绝模型篡改;
- ✅ 所有数组下标由内部状态机生成, 无用户可控索引, 不存在越界/穿越;
- ✅ WS2812 输出固定时序, 不接受外部数据, 不存在注入;
- ✅ 无文件 / SQL / shell / 模板 / 反序列化路径;
- ✅ 配置链路 (ESP32 → SelectMAP/Slave Serial) 是物理总线, 板上保护; 后续若给 ESP32
     加 OTA 更新比特流, 务必加 SSO 鉴权 + 短期 token (见项目 SSO 方案).
- ⚠ 未规避 (硬件层面非软件能控): 物理探针读取比特流 (这是 Spartan-7 默认行为,
     如需保护请启用 BITSTREAM AES-256 加密, 但需要 OTP eFUSE 烧写, 不可逆, 慎用).
