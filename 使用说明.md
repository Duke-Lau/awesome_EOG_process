# BIOPAC MP160 EOG2-R detect-blink 批处理程序使用说明

## 1. 适用数据
本程序面向 **AcqKnowledge 导出的 `.mat` 文件**，并按以下 4 轨定义读取数据：

- 第 1 轨：50 Hz band-stop 后的 **水平眼电**
- 第 2 轨：**原始水平眼电**
- 第 3 轨：50 Hz band-stop 后的 **垂直眼电**
- 第 4 轨：**原始垂直眼电**

程序默认使用 **第 1 轨 + 第 3 轨** 做 detect-blink 概率检测，  
第 2 轨 + 第 4 轨主要用于保存质量控制图与辅助核对。

---

## 2. 运行方法

### 方法 A：直接指定输入目录
```matlab
run_biopac_mp160_detect_blink_batch('E:\你的MAT文件夹')
```

### 方法 B：同时指定输入与输出目录
```matlab
run_biopac_mp160_detect_blink_batch('E:\你的MAT文件夹', 'E:\输出文件夹')
```

---

## 3. 输出内容
程序会在输出目录生成：

- `detect_blink_results.xlsx`
- `debug_mat\*.mat`
- `qc_plots\*.png`

其中 Excel 里有 4 个工作表：

### `BlinkEvents`
逐个眨眼事件的明细表，至少包含：

- `file_name`
- `BLI_PEAK_s`
- `BLI_START_s`
- `BLI_DUR_s`
- `BLI_PROB`
- `BLI_DMM`

并额外输出：

- `BLI_END_s`
- `BLI_PEAK_sample`
- `BLI_START_sample`
- `BLI_END_sample`
- 训练时长、通道号、模型参数等

### `SaccadeEvents`
逐个扫视事件结果：

- `SAC_START_s`
- `SAC_DUR_s`
- `SAC_END_s`
- `SAC_PROB`

### `FileSummary`
每个文件一级的汇总统计：

- 眨眼总数 `N_blinks`
- 扫视总数 `N_saccades`
- 平均眨眼持续时间
- 平均 blink 概率
- 中位数 `BLI_DMM`
- 文件时长、采样率、状态、报错信息等

### `FieldDescription`
各字段中文含义说明表。

---

## 4. 你最可能需要修改的两个位置

打开 `run_biopac_mp160_detect_blink_batch.m` 顶部参数区，优先检查：

### 4.1 采样率
```matlab
cfg.fs = [];
```

- 留空：程序会尝试从 `.mat` 自动识别
- 若失败：请手动改成实际采样率，例如
```matlab
cfg.fs = 500;
```

### 4.2 数据变量名
```matlab
cfg.data_var = '';
```

- 留空：程序自动寻找最像 `N x 4` 的矩阵
- 若失败：请手动填写 `.mat` 文件里的变量名，例如
```matlab
cfg.data_var = 'data';
```

---

## 5. 程序逻辑概述
本程序按你提供的 detect-blink / `eogert_offline` 核心思路实现：

1. 前 `train_secs` 秒做无监督训练
2. 提取 `norm_D` 特征，区分 fixation 与事件
3. 提取 `dmm` 特征，区分 blink 与 saccade
4. 用 EM 高斯混合模型估计分布参数
5. 对后续每个样本计算：
   - `P(fixation)`
   - `P(saccade)`
   - `P(blink)`
6. 将连续概率段整合为事件，得到：
   - `BLI_PEAK`
   - `BLI_START`
   - `BLI_DUR`
   - `BLI_PROB`
   - `BLI_DMM`

---

## 6. 结果解释建议
正式论文分析时，建议你：

- **优先使用 `BLI_START_s` 和 `BLI_DUR_s`**
- `BLI_PEAK_s` 可作为参考，不建议单独作为核心统计量
- 对异常长或异常短的 blink，建议结合 `qc_plots` 人工抽查
- 若不同被试差异较大，可适当调：
  - `cfg.train_secs`
  - `cfg.MIN_BLINK_LEN`
  - `cfg.MAX_BLINK_LEN`

---

## 7. 如果运行失败，优先排查
1. `.mat` 里是不是确实有 4 通道矩阵  
2. 通道顺序是否真的是 `1/2/3/4 = 滤波水平/原始水平/滤波垂直/原始垂直`
3. 采样率是否识别错误
4. 文件时长是否太短，导致训练区不够
5. 某些文件导出的变量名是否和其他文件不同

---
