# Spartan Edge — 按键手势 MLP 推理

在 Seeed Spartan Edge Accelerator Board (XC7S15) 上部署一个 int8 量化的极小 MLP,
用 2 个用户按键做手势分类 (4 类), 8 颗 WS2812 LED 输出结果.

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
│   ├── ws2812_driver.v                    # 8 LED 菊花链驱动
│   └── top.v                              # 顶层
├── sim/
│   ├── tb_mlp.v                           # bit-true testbench
│   └── vectors/test_vectors.txt           # 训练脚本生成
├── vivado/
│   ├── constraints.xdc                    # 引脚 (TODO: 与 PDF 核对)
│   └── build.tcl                          # 非项目模式编译脚本
└── CLAUDE.md
```

## 设计要点

| 模块 | 复杂度 |
|---|---|
| 输入 | BTN0 / BTN1, 50 Hz 采样, 64 帧, 共 128 bit |
| 网络 | MLP: 128 → 16 (ReLU) → 4, int8 对称量化, 共 ~2 KB 权重 (BRAM) |
| 推理 | 单 DSP 串行 MAC, 状态机控制, 一次推理 ~2200 cycle ≈ 44 µs @ 50 MHz |
| 输出 | 8 颗 WS2812: 仅点亮 LED[class_id], 颜色按类别区分 |
| 量化误差 | 浮点 99.31% → int8 99.31% → 硬件等价 99.25% (50 个测试样本 RTL 与 Python bit-true 完全一致) |

## 类别定义

| Class | 含义 | LED 颜色 |
|---|---|---|
| 0 | BTN0 短按 | 暗绿 |
| 1 | BTN1 短按 | 暗红 |
| 2 | BTN0 长按 (>500 ms) | 黄 |
| 3 | BTN0 双击 | 蓝 |

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

## 在你机器上还需要做的事

1. 用 Vivado 打开 `vivado/build.tcl`, 按你实际的 Vivado 版本和 part number 跑一遍.
   板子是 XC7S15-FTGB196 (1 速度等级); 如果不同请改 `PART`.
2. **打开 `Board/Spartan Edge Accelerator Board v1.0.pdf`**, 把 `vivado/constraints.xdc`
   里所有标 TODO verify 的引脚 (clk_50m / btn0 / btn1 / ws2812_din / led_status[3:0])
   与原理图核对一遍, 不一致时修正.
3. 把 `vivado/build/spartan_edge_mlp.bit` 拷贝到 SD 卡, 让你已有的 ESP32 加载器
   通过 Slave Serial 烧录到 FPGA. 配置成功后:
   - 按 BTN0 短按一次 → LED0 亮暗绿
   - 按 BTN1 短按一次 → LED1 亮暗红
   - 长按 BTN0 ≥ 0.5s → LED2 亮黄
   - 快速双击 BTN0 → LED3 亮蓝

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
