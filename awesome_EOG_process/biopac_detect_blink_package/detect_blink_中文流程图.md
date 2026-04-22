# detect-blink 中文流程图（带注释）

```mermaid
flowchart TD
    A[输入 BIOPAC MP160 Acq 导出的 4 轨 .mat 文件<br/>1=滤波水平 2=原始水平 3=滤波垂直 4=原始垂直] --> B[读取数据并提取第1轨与第3轨<br/>作为 detect-blink 主分析信号]
    B --> C[前 train_secs 秒无监督训练]
    C --> D[1 Hz FIR 因果滤波<br/>得到平滑水平/垂直信号]
    C --> E[40 Hz FIR 因果滤波<br/>保留较快变化用于定位事件边界]
    D --> F[计算一阶差分 Hd, Vd]
    E --> G[计算一阶差分 Hd2, Vd2]
    F --> H[特征1：norm_D = sqrt(Hd^2 + Vd^2)<br/>作用：区分 fixation 与 事件]
    F --> I[特征2：dmm<br/>作用：强调围绕0近似对称的垂直峰<br/>更利于区分 blink 与 saccade]
    H --> J[EM 两高斯拟合<br/>得到 fixation 与 blink/saccade 的分布参数]
    I --> K[EM 两高斯拟合<br/>得到 saccade 与 blink 的分布参数]
    J --> L[逐样本计算 P(fixation)]
    K --> M[逐样本计算 P(saccade)、P(blink)]
    L --> N{哪个概率最大?}
    M --> N
    N -->|P(blink) 最大| O[进入 blink 连续段]
    N -->|P(saccade) 最大| P[进入 saccade 连续段]
    N -->|P(fixation) 最大| Q[视为注视/间隔]
    O --> R[事件结束后回溯局部峰值<br/>估计 BLI_PEAK、BLI_START、BLI_DUR]
    P --> S[事件结束后估计 SAC_START、SAC_DUR]
    R --> T[事件级筛选<br/>持续时间/概率质量/不重叠检查]
    S --> U[事件级筛选<br/>最小间隔/最小时长检查]
    T --> V[输出 BlinkEvents 表]
    U --> W[输出 SaccadeEvents 表]
    V --> X[汇总到 FileSummary]
    W --> X
    X --> Y[写出 xlsx<br/>BlinkEvents / SaccadeEvents / FileSummary / FieldDescription]
```

## 关键注释
- `norm_D`：把水平和垂直导数合成一个强度指标，先判断当前是不是发生了“眼动事件”。
- `dmm`：更强调垂直通道中“近似对称”的峰形，blink 往往比普通 saccade 更符合这一特征。
- `EM 两高斯拟合`：前一段数据不需要人工标注，算法自己拟合出“静息/事件”和“扫视/眨眼”的统计分布。
- `概率最大判别`：不是固定阈值法，而是逐点比较 `P(fixation)`、`P(saccade)`、`P(blink)`。
- `事件级筛选`：避免把噪声、伪峰、过短波动当成 blink。
