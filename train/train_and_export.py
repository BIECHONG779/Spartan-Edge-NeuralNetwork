"""
train_and_export.py — Spartan Edge 按键手势 MLP (4 类: 长按/双击 × 2 按键)

合成数据 → 训练 (numpy) → int8 对称量化 → 导出 .mem & 参考向量
所有产物输出到 ../rtl/mem/ 与 ../sim/vectors/

依赖：仅 numpy
"""
import os
import numpy as np

np.random.seed(42)

# ---------- 1. 合成数据集 ----------
# 输入: 64 frame × 2 bit (BTN0,BTN1) = 128-D 0/1 向量
# 类别: 0=USER1长按, 1=USER1双击, 2=USER2长按, 3=USER2双击
N_FRAMES = 64        # 50Hz 采样, 1.28s 窗口
INPUT_DIM = N_FRAMES * 2
HIDDEN = 16
N_CLASSES = 4

def synth_sample(cls, rng):
    x = np.zeros((N_FRAMES, 2), dtype=np.uint8)
    if cls == 0:                     # USER1 长按 >=25 frame
        start = rng.integers(2, 10)
        dur = rng.integers(25, N_FRAMES - start - 1)
        x[start:start + dur, 0] = 1
    elif cls == 1:                   # USER1 双击 (两段短按 + 间隔)
        start1 = rng.integers(2, 12)
        d1 = rng.integers(3, 8)
        gap = rng.integers(3, 8)
        d2 = rng.integers(3, 8)
        s2 = start1 + d1 + gap
        x[start1:start1 + d1, 0] = 1
        if s2 + d2 < N_FRAMES:
            x[s2:s2 + d2, 0] = 1
    elif cls == 2:                   # USER2 长按 >=25 frame
        start = rng.integers(2, 10)
        dur = rng.integers(25, N_FRAMES - start - 1)
        x[start:start + dur, 1] = 1
    elif cls == 3:                   # USER2 双击 (两段短按 + 间隔)
        start1 = rng.integers(2, 12)
        d1 = rng.integers(3, 8)
        gap = rng.integers(3, 8)
        d2 = rng.integers(3, 8)
        s2 = start1 + d1 + gap
        x[start1:start1 + d1, 1] = 1
        if s2 + d2 < N_FRAMES:
            x[s2:s2 + d2, 1] = 1
    # 加 1% bit-flip 抖动
    flip = rng.random((N_FRAMES, 2)) < 0.01
    x = np.where(flip, 1 - x, x)
    return x.flatten().astype(np.float32)

def build_dataset(n_per_class=2000, seed=0):
    rng = np.random.default_rng(seed)
    X, Y = [], []
    for c in range(N_CLASSES):
        for _ in range(n_per_class):
            X.append(synth_sample(c, rng))
            Y.append(c)
    X = np.stack(X); Y = np.array(Y)
    idx = rng.permutation(len(X))
    return X[idx], Y[idx]

print('[1/5] building dataset...')
X_train, Y_train = build_dataset(2000, seed=1)
X_test,  Y_test  = build_dataset(400,  seed=2)

# ---------- 2. 浮点 MLP 训练（手写 SGD） ----------
def init_w(fan_in, fan_out, rng):
    return (rng.standard_normal((fan_in, fan_out)) * np.sqrt(2.0 / fan_in)).astype(np.float32)

rng = np.random.default_rng(0)
W1 = init_w(INPUT_DIM, HIDDEN, rng)
b1 = np.zeros(HIDDEN, dtype=np.float32)
W2 = init_w(HIDDEN, N_CLASSES, rng)
b2 = np.zeros(N_CLASSES, dtype=np.float32)

def forward(x):
    h = np.maximum(0, x @ W1 + b1)
    o = h @ W2 + b2
    return h, o

def softmax_ce_grad(o, y):
    p = np.exp(o - o.max(axis=1, keepdims=True))
    p /= p.sum(axis=1, keepdims=True)
    grad = p.copy()
    grad[np.arange(len(y)), y] -= 1
    return grad / len(y)

print('[2/5] training float MLP...')
LR = 0.05
EPOCHS = 25
BS = 64
for ep in range(EPOCHS):
    perm = rng.permutation(len(X_train))
    for i in range(0, len(X_train), BS):
        idx = perm[i:i + BS]
        xb, yb = X_train[idx], Y_train[idx]
        h, o = forward(xb)
        do = softmax_ce_grad(o, yb)
        dW2 = h.T @ do; db2 = do.sum(0)
        dh = do @ W2.T
        dh[h <= 0] = 0
        dW1 = xb.T @ dh; db1 = dh.sum(0)
        W2 -= LR * dW2; b2 -= LR * db2
        W1 -= LR * dW1; b1 -= LR * db1
    if (ep + 1) % 5 == 0:
        _, o_te = forward(X_test)
        acc = (o_te.argmax(1) == Y_test).mean()
        print(f'  epoch {ep+1:2d}: float test acc = {acc*100:.2f}%')

_, o_te = forward(X_test)
float_acc = (o_te.argmax(1) == Y_test).mean()
print(f'  float final acc = {float_acc*100:.2f}%')

# ---------- 3. int8 对称量化 ----------
print('[3/5] quantizing weights to int8...')

def quant_w(W):
    s = np.abs(W).max() / 127.0
    Wq = np.round(W / s).clip(-127, 127).astype(np.int8)
    return Wq, s

W1q, s1 = quant_w(W1)
W2q, s2 = quant_w(W2)
SX = 1.0 / 127.0
b1q = np.round(b1 / (SX * s1)).astype(np.int32)

h_train = np.maximum(0, X_train @ W1 + b1)
s_h = h_train.max() / 127.0  # ReLU 后非负, 无需对称
b2q = np.round(b2 / (s_h * s2)).astype(np.int32)

def infer_int8(x_bit):
    xq = (x_bit * 127).astype(np.int32)
    acc1 = xq @ W1q.astype(np.int32) + b1q
    h_real = acc1.astype(np.float32) * (SX * s1)
    hq = np.clip(np.round(np.maximum(0, h_real) / s_h), 0, 127).astype(np.int32)
    acc2 = hq @ W2q.astype(np.int32) + b2q
    return acc2.argmax(1), acc2

print('[4/5] verifying quantized accuracy...')
pred_q, _ = infer_int8(X_test.astype(np.uint8))
q_acc = (pred_q == Y_test).mean()
print(f'  int8 test acc  = {q_acc*100:.2f}%   (float was {float_acc*100:.2f}%)')

# ---------- 4. 为硬件导出 ----------
def to_fixed_mul(scale, shift_bits=15):
    m = int(round(scale * (1 << shift_bits)))
    return m, shift_bits

REQUANT_MUL, REQUANT_SHIFT = to_fixed_mul(SX * s1 / s_h, 15)
print(f'  requant: scale={SX*s1/s_h:.6f}  ->  ({REQUANT_MUL} >> {REQUANT_SHIFT})')

def infer_hw(x_bit):
    xq = (x_bit * 127).astype(np.int32)
    acc1 = xq @ W1q.astype(np.int32) + b1q
    acc1_relu = np.maximum(0, acc1)
    hq = (acc1_relu * REQUANT_MUL) >> REQUANT_SHIFT
    hq = np.clip(hq, 0, 127).astype(np.int32)
    acc2 = hq @ W2q.astype(np.int32) + b2q
    return acc2.argmax(1), acc2

pred_hw, _ = infer_hw(X_test.astype(np.uint8))
hw_acc = (pred_hw == Y_test).mean()
print(f'  hw-equiv  acc  = {hw_acc*100:.2f}%')

# ---------- 5. 写文件 ----------
mem_dir = os.path.join(os.path.dirname(__file__), '..', 'rtl', 'mem')
vec_dir = os.path.join(os.path.dirname(__file__), '..', 'sim', 'vectors')
os.makedirs(mem_dir, exist_ok=True)
os.makedirs(vec_dir, exist_ok=True)

def write_mem_signed8(path, arr_2d_or_1d):
    flat = arr_2d_or_1d.flatten().astype(np.int32)
    with open(path, 'w') as f:
        for v in flat:
            f.write(f'{v & 0xFF:02x}\n')

def write_mem_signed32(path, arr):
    flat = arr.flatten().astype(np.int64)
    with open(path, 'w') as f:
        for v in flat:
            f.write(f'{v & 0xFFFFFFFF:08x}\n')

write_mem_signed8 (os.path.join(mem_dir, 'w1.mem'), W1q)   # 128*16 = 2048 行
write_mem_signed32(os.path.join(mem_dir, 'b1.mem'), b1q)   # 16 行
write_mem_signed8 (os.path.join(mem_dir, 'w2.mem'), W2q)   # 16*4  = 64 行
write_mem_signed32(os.path.join(mem_dir, 'b2.mem'), b2q)   # 4 行

# 测试向量
n_vec = 50
with open(os.path.join(vec_dir, 'test_vectors.txt'), 'w') as f:
    f.write(f'# requant_mul={REQUANT_MUL} requant_shift={REQUANT_SHIFT}\n')
    f.write(f'# format: <128bit_hex_msb_first> <expected_class>\n')
    for i in range(n_vec):
        x = X_test[i].astype(np.uint8)
        bits = 0
        for k in range(INPUT_DIM):
            bits = (bits << 1) | int(x[k])
        f.write(f'{bits:032x} {int(pred_hw[i])}\n')

# Verilog define
with open(os.path.join(mem_dir, 'params.vh'), 'w') as f:
    f.write('// Auto-generated by train/train_and_export.py — do not edit\n')
    f.write(f'`define INPUT_DIM   {INPUT_DIM}\n')
    f.write(f'`define HIDDEN      {HIDDEN}\n')
    f.write(f'`define N_CLASSES   {N_CLASSES}\n')
    f.write(f'`define REQ_MUL     {REQUANT_MUL}\n')
    f.write(f'`define REQ_SHIFT   {REQUANT_SHIFT}\n')

print('[5/5] artifacts written:')
print('  rtl/mem/w1.mem  w2.mem  b1.mem  b2.mem  params.vh')
print('  sim/vectors/test_vectors.txt')
print('done.')
