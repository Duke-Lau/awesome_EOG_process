
function run_biopac_mp160_detect_blink_batch(input_dir, output_dir)
%==========================================================================
% run_biopac_mp160_detect_blink_batch
%
% 适用对象：
%   处理 BIOPAC MP160 / AcqKnowledge 导出的 4 轨 .mat 文件。
%
% 你的通道约定（按用户说明）：
%   第1轨 = 已做 FIR band-stop 50 Hz 的水平眼电（filtered horizontal EOG）
%   第2轨 = 原始水平眼电（raw horizontal EOG）
%   第3轨 = 已做 FIR band-stop 50 Hz 的垂直眼电（filtered vertical EOG）
%   第4轨 = 原始垂直眼电（raw vertical EOG）
%
% 本程序做什么：
%   1. 批量读取文件夹中的 .mat 文件
%   2. 自动寻找 4 通道数据矩阵（常见 Acq 导出结构）
%   3. 基于 detect-blink / eogert_offline 的核心思路：
%      - 前 train_secs 秒无监督训练
%      - 提取 norm_D 与 dmm 两类特征
%      - EM 高斯混合建模
%      - 概率区分 fixation / saccade / blink
%   4. 输出 xlsx 结果，至少包含：
%      文件名、BLI_PEAK、BLI_START、BLI_DUR、BLI_PROB、BLI_DMM
%   5. 同时输出更多字段与汇总统计
%
% 输出文件：
%   output_dir/detect_blink_results.xlsx
%   output_dir/debug_mat/*.mat
%   output_dir/qc_plots/*.png   （可选）
%
% 运行方式示例：
%   run_biopac_mp160_detect_blink_batch('E:\your_mat_folder')
%   run_biopac_mp160_detect_blink_batch('E:\your_mat_folder', 'E:\your_output')
%
% 如果自动识别失败：
%   请手动修改下方 cfg.data_var 或 cfg.fs
%
% 作者说明：
%   本程序是根据你提供的 eogert_offline 思路做的工程化离线批处理版本，
%   适配 xlsx 输出与 BIOPAC MP160 的 .mat 批量处理需求。
%==========================================================================

    if nargin < 1 || isempty(input_dir)
        input_dir = pwd;
    end
    if nargin < 2 || isempty(output_dir)
        output_dir = fullfile(input_dir, 'detect_blink_output_normalOB_180');
    end

    if ~exist(output_dir, 'dir')
        mkdir(output_dir);
    end
    debug_dir = fullfile(output_dir, 'debug_mat');
    if ~exist(debug_dir, 'dir')
        mkdir(debug_dir);
    end
    qc_dir = fullfile(output_dir, 'qc_plots');
    if ~exist(qc_dir, 'dir')
        mkdir(qc_dir);
    end

    %% ===================== 用户可调参数区 =====================
    cfg = struct();

    % ---- 数据读取相关 ----
    cfg.data_var = 'data';     % 如果你知道 .mat 里的主数据变量名，可直接写，如 'data'
    cfg.fs = 2000;           % 留空 = 自动识别；若自动失败，请手动写采样率，如 500 或 1000
    cfg.verbose = true;

    % ---- 通道映射：按你的说明固定为 1/2/3/4 ----
    cfg.filtered_h_ch = 1; % 已滤波 水平眼电
    cfg.raw_h_ch      = 2; % 原始   水平眼电
    cfg.filtered_v_ch = 4; % 已滤波 垂直眼电
    cfg.raw_v_ch      = 3; % 原始   垂直眼电

    % ---- detect-blink 训练 / 事件阈值 ----
    cfg.train_secs       = 180;     % 前 10 秒用于无监督训练；数据太短时可改小
    cfg.MIN_SACCADE_GAP  = 0.100;  % 两次扫视之间最小间隔（秒）
    cfg.MIN_SACCADE_LEN  = 0.010;  % 最短扫视
    cfg.MAX_SACCADE_LEN  = 0.150;  % 最长扫视（对应缓冲上限）
    cfg.MIN_BLINK_LEN    = 0.030;  % 最短眨眼
    cfg.MAX_BLINK_LEN    = 0.500;  % 最长眨眼

    % ---- 滤波参数（沿用原思路）----
    cfg.FIRlen       = 150;  % FIR 滤波器长度
    cfg.pass_limit1  = 1;    % 第一组低通：1 Hz
    cfg.pass_limit2  = 40;   % 第二组低通：40 Hz

    % ---- 结果输出 ----
    cfg.save_qc_plot = false;  % 是否保存质量控制图
    cfg.save_debug_mat = false; % 是否保存每个文件的中间结果 mat
    cfg.xlsx_name = 'total_AR_Blink_nOB1.xlsx';

    %% ===================== 批量处理开始 =====================
    mat_files = dir(fullfile(input_dir, '*.mat'));
    if isempty(mat_files)
        error('在输入文件夹中没有找到 .mat 文件：%s', input_dir);
    end

    % 预建空表，避免某些文件没有 blink 时出错
    blink_events_all = initBlinkEventTable();
    saccade_events_all = initSaccadeEventTable();
    summary_all = initSummaryTable();
    field_desc = buildFieldDescriptionTable();

    fprintf('=============================================\n');
    fprintf('开始批处理 detect-blink（BIOPAC MP160 EOG2-R）\n');
    fprintf('输入目录：%s\n', input_dir);
    fprintf('输出目录：%s\n', output_dir);
    fprintf('文件数量：%d\n', numel(mat_files));
    fprintf('=============================================\n');

    for i = 1:numel(mat_files)
        file_name = mat_files(i).name;
        file_path = fullfile(mat_files(i).folder, file_name);

        fprintf('\n[%d/%d] 正在处理：%s\n', i, numel(mat_files), file_name);

        try
            %--------------------------------------------------------------
            % 1) 读取 .mat 数据并自动提取 4 通道矩阵
            %--------------------------------------------------------------
            [sig4, meta] = readBiopac4ChMat(file_path, cfg);

            % 安全检查
            if size(sig4,2) < 4
                error('识别到的数据列数少于 4，无法按 1/2/3/4 轨映射。');
            end

            % 提取各通道
            h_filt = sig4(:, cfg.filtered_h_ch);   % 已滤波水平
            h_raw  = sig4(:, cfg.raw_h_ch);        % 原始水平
            v_filt = sig4(:, cfg.filtered_v_ch);   % 已滤波垂直
            v_raw  = sig4(:, cfg.raw_v_ch);        % 原始垂直

            fs = meta.fs;
            duration_s = numel(h_filt) / fs;

            % 如果文件很短，自动缩短训练时长
            train_secs_this = min(cfg.train_secs, max(2, floor(duration_s/5)));
            if train_secs_this >= duration_s - 1
                train_secs_this = max(1, floor(duration_s/4));
            end
            if train_secs_this < 1
                error('文件时长过短（%.3f s），不足以进行训练和检测。', duration_s);
            end

            %--------------------------------------------------------------
            % 2) 概率式 detect-blink 检测
            %--------------------------------------------------------------
            result = detectBlinkProbabilisticOffline(h_filt, v_filt, fs, train_secs_this, cfg);

            %--------------------------------------------------------------
            % 3) 整理 blink 事件表
            %--------------------------------------------------------------
            blink_tbl = resultToBlinkTable(result, file_name, fs, numel(h_filt), duration_s, train_secs_this, cfg);
            blink_events_all = [blink_events_all; blink_tbl]; %#ok<AGROW>

            %--------------------------------------------------------------
            % 4) 整理 saccade 事件表
            %--------------------------------------------------------------
            sac_tbl = resultToSaccadeTable(result, file_name);
            saccade_events_all = [saccade_events_all; sac_tbl]; %#ok<AGROW>

            %--------------------------------------------------------------
            % 5) 文件级汇总
            %--------------------------------------------------------------
            summary_row = buildSummaryRow(result, file_name, fs, numel(h_filt), duration_s, train_secs_this, meta, cfg, "成功", "");
            summary_all = [summary_all; summary_row]; %#ok<AGROW>

            %--------------------------------------------------------------
            % 6) 保存调试 mat
            %--------------------------------------------------------------
            if cfg.save_debug_mat
                debug_result = result; 
                debug_meta = meta; 
                raw_signals = table(h_filt, h_raw, v_filt, v_raw); 
                save(fullfile(debug_dir, [erase(file_name, '.mat') '_debug.mat']), ...
                    'debug_result', 'debug_meta', 'raw_signals');
            end

            %--------------------------------------------------------------
            % 7) 保存 QC 图
            %--------------------------------------------------------------
            if cfg.save_qc_plot
                saveQCPlot(file_name, h_filt, v_filt, h_raw, v_raw, fs, result, qc_dir);
            end

            fprintf('  检测完成：blink=%d, saccade=%d, 时长=%.2f s, fs=%.3f Hz\n', ...
                result.Nblinks, result.Nsacs, duration_s, fs);

        catch ME
            fprintf('  处理失败：%s\n', ME.message);
            summary_row = buildSummaryRow(struct(), file_name, NaN, NaN, NaN, NaN, struct(), cfg, "失败", string(ME.message));
            summary_all = [summary_all; summary_row]; %#ok<AGROW>
        end
    end

    %% ===================== 写出 Excel =====================
    xlsx_path = fullfile(output_dir, cfg.xlsx_name);

    % 为了兼容 MATLAB，不同 sheet 分别写
    writetable(blink_events_all,   xlsx_path, 'Sheet', 'BlinkEvents');
    writetable(saccade_events_all, xlsx_path, 'Sheet', 'SaccadeEvents');
    writetable(summary_all,        xlsx_path, 'Sheet', 'FileSummary');
    writetable(field_desc,         xlsx_path, 'Sheet', 'FieldDescription');

    fprintf('\n=============================================\n');
    fprintf('全部处理完成。\n');
    fprintf('Excel 结果：%s\n', xlsx_path);
    fprintf('=============================================\n');
end

%% =========================================================================
function [sig4, meta] = readBiopac4ChMat(file_path, cfg)
% 读取 AcqKnowledge 导出的 .mat
% 目标：自动找到一个 4 通道数值矩阵，并尽量自动识别采样率

    S = load(file_path);
    meta = struct();
    meta.file_path = string(file_path);
    meta.data_var_used = "";
    meta.fs = NaN;

    % 1) 若用户手动指定了变量名，优先使用
    if ~isempty(cfg.data_var)
        if isfield(S, cfg.data_var)
            X = S.(cfg.data_var);
            [sig4, ok] = normalizeSignalMatrix(X);
            if ok
                meta.data_var_used = string(cfg.data_var);
            else
                error('指定变量 %s 存在，但不是可识别的 4 通道矩阵。', cfg.data_var);
            end
        else
            error('指定的数据变量 %s 在文件中不存在。', cfg.data_var);
        end
    else
        % 2) 自动寻找最像 4 通道数据的变量
        [sig4, data_var_name] = autoFind4ChannelMatrix(S);
        if isempty(sig4)
            error(['自动识别 4 通道矩阵失败。请手动打开 .mat 看变量名，' ...
                   '然后把 cfg.data_var 设置成对应变量名。']);
        end
        meta.data_var_used = string(data_var_name);
    end

    % 3) 自动识别采样率
    fs_found = tryDetectFs(S);
    if isempty(cfg.fs)
        if isempty(fs_found) || ~isfinite(fs_found) || fs_found <= 0
            error(['未能从 .mat 中自动识别采样率。' ...
                   '请在程序顶部把 cfg.fs 手动设置成你的实际采样率，例如 500 或 1000。']);
        else
            meta.fs = fs_found;
        end
    else
        meta.fs = cfg.fs;
    end

    % 4) 元信息
    meta.n_samples = size(sig4,1);
    meta.n_channels = size(sig4,2);

    % 5) 基本长度检查
    if size(sig4,1) < 50
        error('有效样本点过少（<50），无法进行可靠检测。');
    end
end

%% =========================================================================
function [sig4, data_var_name] = autoFind4ChannelMatrix(S)
% 在 load 出来的结构体中自动找最像 4 通道数据的数值矩阵
    sig4 = [];
    data_var_name = "";

    candidates = {};
    cand_names = {};

    fns = fieldnames(S);
    for i = 1:numel(fns)
        fn = fns{i};
        val = S.(fn);

        % 顶层数值矩阵
        if isnumeric(val) && ismatrix(val)
            [X, ok] = normalizeSignalMatrix(val);
            if ok
                candidates{end+1} = X; %#ok<AGROW>
                cand_names{end+1} = fn; %#ok<AGROW>
            end
        end

        % 一层嵌套 struct
        if isstruct(val) && isscalar(val)
            subfns = fieldnames(val);
            for j = 1:numel(subfns)
                sfn = subfns{j};
                subv = val.(sfn);
                if isnumeric(subv) && ismatrix(subv)
                    [X, ok] = normalizeSignalMatrix(subv);
                    if ok
                        candidates{end+1} = X; %#ok<AGROW>
                        cand_names{end+1} = string(fn) + "." + string(sfn); %#ok<AGROW>
                    end
                end
            end
        end
    end

    if isempty(candidates)
        return;
    end

    % 选样本数最多的那个
    lens = cellfun(@(x) size(x,1), candidates);
    [~, idx] = max(lens);
    sig4 = candidates{idx};
    data_var_name = cand_names{idx};
end

%% =========================================================================
function [Xn, ok] = normalizeSignalMatrix(X)
% 把矩阵规范成 [N x C]
% 规则：
%   - 若是 N x C，且 C >= 4，直接用
%   - 若是 C x N，且 C >= 4，转置
%   - 其他情况，不认

    ok = false;
    Xn = [];

    if ~isnumeric(X) || ~ismatrix(X) || isempty(X)
        return;
    end

    [r, c] = size(X);

    % 情况1：样本在行，通道在列
    if r > c && c >= 4
        Xn = double(X);
        ok = true;
        return;
    end

    % 情况2：样本在列，通道在行
    if c > r && r >= 4
        Xn = double(X.');
        ok = true;
        return;
    end
end

%% =========================================================================
%%function [Xn, ok] = normalizeSignalMatrix(X)
% 把矩阵规范成 [N x 4]
% 规则：
%   - 若是 N x 4，直接用
%   - 若是 4 x N，转置
%   - 其他情况，不认
%    ok = false;
%    Xn = [];

%   if ~isnumeric(X) || ~ismatrix(X) || isempty(X)
%        return;
%    end

%    [r, c] = size(X);

%    if c == 4 && r > 4
%        Xn = double(X);
%        ok = true;
%        return;
%    end

%    if r == 4 && c > 4
%        Xn = double(X.');
%        ok = true;
%        return;
%    end
%end

%% =========================================================================
function fs = tryDetectFs(S)
% 尽量从常见字段中自动识别采样率
% 常见策略：
%   - fs / Fs / srate / SampleRate / sampleRate
%   - isi / sample_interval / dt
% 注意：Acq 导出的 .mat 结构并不总一致，所以这里只做“尽力检测”

    fs = [];

    % 优先直接找“采样率”
    keys_fs = {'fs','Fs','FS','srate','SRate','sampleRate','SampleRate','samplingRate','SamplingRate'};
    [hit, val] = searchScalarFieldRecursive(S, keys_fs);
    if hit && isfinite(val) && val > 0
        fs = double(val);
        return;
    end

    % 再尝试找采样间隔
    keys_dt = {'isi','ISI','dt','DT','sample_interval','SampleInterval','delta_t','DeltaT'};
    [hit, val] = searchScalarFieldRecursive(S, keys_dt);
    if hit && isfinite(val) && val > 0
        val = double(val);

        % 经验判断：
        %   若 val < 1，通常看作秒
        %   若 1 <= val < 100，很多情况下是毫秒
        %   若更大，则基本不可信
        if val < 1
            fs = 1 / val;
            return;
        elseif val >= 1 && val < 100
            fs = 1000 / val;
            return;
        end
    end
end

%% =========================================================================
function [hit, val] = searchScalarFieldRecursive(S, keys)
    hit = false;
    val = [];

    if ~isstruct(S)
        return;
    end

    fns = fieldnames(S);
    for i = 1:numel(fns)
        fn = fns{i};
        fv = S.(fn);

        for k = 1:numel(keys)
            if strcmpi(fn, keys{k})
                if isnumeric(fv) && isscalar(fv)
                    hit = true;
                    val = double(fv);
                    return;
                end
            end
        end

        if isstruct(fv) && isscalar(fv)
            [hit_sub, val_sub] = searchScalarFieldRecursive(fv, keys);
            if hit_sub
                hit = true;
                val = val_sub;
                return;
            end
        end
    end
end

%% =========================================================================
function result = detectBlinkProbabilisticOffline(h, v, fs, train_secs, cfg)
% 这是对 eogert_offline 思路的离线工程化改写版本
% 核心不变：
%   1) 前 train_secs 秒做无监督训练
%   2) 用 norm_D 区分 fixation vs (blink/saccade)
%   3) 用 dmm 区分 blink vs saccade
%   4) 通过概率序列确定事件起止与持续时间

    % -------- 安全整理成列向量 --------
    h = double(h(:));
    v = double(v(:));
    N = numel(h);
    if numel(v) ~= N
        error('水平和垂直眼电长度不一致。');
    end

    % -------- 读取参数 --------
    MIN_SACCADE_GAP = cfg.MIN_SACCADE_GAP;
    MIN_SACCADE_LEN = cfg.MIN_SACCADE_LEN;
    MAX_SACCADE_LEN = cfg.MAX_SACCADE_LEN;
    MIN_BLINK_LEN   = cfg.MIN_BLINK_LEN;
    MAX_BLINK_LEN   = cfg.MAX_BLINK_LEN;

    FIRlen = cfg.FIRlen;
    pass_limit1 = cfg.pass_limit1;
    pass_limit2 = cfg.pass_limit2;

    % -------- 设计滤波器 --------
    Bfir  = fir1(FIRlen, pass_limit1/(fs/2));  % 1 Hz 低通
    Bfir2 = fir1(FIRlen, pass_limit2/(fs/2));  % 40 Hz 低通
    groupDelay = (FIRlen - 1) / 2;

    % -------- 因果滤波（与原思路一致）--------
    hf_rec  = filter(Bfir,  1, h);
    vf_rec  = filter(Bfir,  1, v);
    hf_rec2 = filter(Bfir2, 1, h);
    vf_rec2 = filter(Bfir2, 1, v);

    % 一阶差分
    Hd  = [0; diff(hf_rec)];
    Vd  = [0; diff(vf_rec)];
    Hd2 = [0; diff(hf_rec2)];
    Vd2 = [0; diff(vf_rec2)];

    % -------- 训练区间 --------
    training_period = round(fs * train_secs);
    burn_off = 2 * FIRlen - 1;

    if training_period <= burn_off + 20
        error('训练区间过短。当前 train_secs=%.3f s，建议增大 train_secs 或检查 fs。', train_secs);
    end

    % ======== 训练阶段：特征1，norm_peak ========
    dh_tr = diff(hf_rec(burn_off:training_period));
    dv_tr = diff(vf_rec(burn_off:training_period));

    norm_tr = sqrt(dh_tr.^2 + dv_tr.^2);

    curr_max = norm_tr(1);
    curr_min = norm_tr(1);
    norm_peak = [];
    tmp_i = 1; %#ok<NASGU>
    for i = 1:length(norm_tr)
        if norm_tr(i) > curr_max
            curr_max = norm_tr(i);
            curr_min = curr_max;
            tmp_i = i;
        end
        if norm_tr(i) < curr_min
            curr_min = norm_tr(i);
        else
            if curr_max > curr_min
                norm_peak = [norm_peak; curr_max]; %#ok<AGROW>
            end
            curr_max = curr_min;
        end
    end

    if numel(norm_peak) < 10
        error('训练阶段提取到的 norm_peak 太少，无法稳定建模。');
    end

    [mu_norm, sigma_norm, P_norm] = EMgauss1D(sort(norm_peak), 2);
    [mu_norm, sigma_norm, P_norm] = sortGMM(mu_norm, sigma_norm, P_norm);
    mu_fix = mu_norm(1); sigma_fix = sigma_norm(1); prior_fix = P_norm(1);
    mu_bs  = mu_norm(2); sigma_bs  = sigma_norm(2); prior_bs  = P_norm(2);

    % ======== 训练阶段：特征2，dmm ========
    curr_max = dv_tr(1);
    curr_min = dv_tr(1);
    diff_max_min = [];
    for i = 1:length(dv_tr)
        if dv_tr(i) > curr_max
            curr_max = dv_tr(i);
            curr_min = curr_max;
            tmp_i = i;
        end
        if dv_tr(i) < curr_min
            curr_min = dv_tr(i);
        else
            if curr_max > curr_min
                ntr = norm_tr(min(i, length(norm_tr)));
                p_bs = safeNormpdf(ntr, mu_bs, sigma_bs) * prior_bs;
                p_fx = safeNormpdf(ntr, mu_fix, sigma_fix) * prior_fix;
                denom = p_bs + p_fx;
                if denom <= 0
                    p_bs = 0;
                else
                    p_bs = p_bs / denom;
                end

                % 这里只保留更像 blink/saccade 的峰
                if p_bs > 2/3
                    feature = curr_max - curr_min - abs(curr_max + curr_min);
                    if feature > 0
                        diff_max_min = [diff_max_min; feature]; %#ok<AGROW>
                    end
                end
            end
            curr_max = curr_min;
        end
    end

    if numel(diff_max_min) < 10
        % 若训练样本太少，退化用粗略分位数初始化
        diff_max_min = max(diff_max_min, eps);
        if numel(diff_max_min) < 2
            diff_max_min = [eps; 2*eps; 3*eps; 4*eps; 5*eps; 6*eps; 7*eps; 8*eps; 9*eps; 10*eps];
        end
    end

    [mu_dmm, sigma_dmm, P_mm] = EMgauss1D(sort(diff_max_min), 2);
    [mu_dmm, sigma_dmm, P_mm] = sortGMM(mu_dmm, sigma_dmm, P_mm);
    mu_sac = mu_dmm(1); sigma_sac = sigma_dmm(1); prior_sac = P_mm(1);
    mu_bli = mu_dmm(2); sigma_bli = sigma_dmm(2); prior_bli = P_mm(2);

    % -------- 在线判别阶段的状态变量 --------
    saccade_on = false;
    saccade_samples = 0;
    saccade_prob = 0;

    blink_on = false;
    blink_samples = 0;
    blink_prob = 0;

    Nsacs = 0;
    Nblinks = 0;

    % 预分配
    DMM = nan(N,1);
    ND = nan(N,1);
    ND2 = nan(N,1);
    PFN = nan(N,1);
    PSN = nan(N,1);
    PBN = nan(N,1);

    curr_vd_max = Vd(training_period + 1);
    vd_prev = Vd(training_period + 1);
    peak_n = training_period + 1;
    sac_on_start_n = NaN;
    sac_on_end_prev_n = training_period + 1;

    SAC_START = [];
    SAC_DUR = [];
    SAC_PROB = [];

    BLI_PEAK = [];
    BLI_START = [];
    BLI_DUR = [];
    BLI_PROB = [];
    BLI_DMM = [];

    % -------- 主循环：概率判别 fixation / saccade / blink --------
    for n = training_period + 1 : N

        % ====== 计算 dmm 与 norm_D 两类特征 ======
        if Vd(n) > vd_prev
            curr_vd_max = Vd(n);
            peak_n = n;
        end
        vd_prev = Vd(n);

        % dmm 越大，越倾向于“围绕 0 对称的峰”，更像 blink
        dmm = curr_vd_max - Vd(n) - abs(curr_vd_max + Vd(n));
        DMM(n) = dmm;

        norm_D  = hypot(Hd(n),  Vd(n));
        norm_D2 = hypot(Hd2(n), Vd2(n));
        ND(n)  = norm_D;
        ND2(n) = norm_D2;

        % ====== 第1层：fixation vs (blink/saccade) ======
        if norm_D > mu_fix
            Lf = safeNormpdf(norm_D, mu_fix, sigma_fix);
        else
            Lf = safeNormpdf(mu_fix, mu_fix, sigma_fix);
        end

        if norm_D < mu_bs
            Lbs = safeNormpdf(norm_D, mu_bs, sigma_bs);
        else
            Lbs = safeNormpdf(mu_bs, mu_bs, sigma_bs);
        end

        evi_norm = Lf * prior_fix + Lbs * prior_bs;
        if evi_norm <= 0
            pfn = 0.5;
        else
            pfn = Lf * prior_fix / evi_norm;
        end
        psbn = 1 - pfn;

        % ====== 第2层：blink vs saccade ======
        if dmm > mu_sac
            Ls = safeNormpdf(dmm, mu_sac, sigma_sac);
        else
            Ls = safeNormpdf(mu_sac, mu_sac, sigma_sac);
        end

        if dmm < mu_bli
            Lb = safeNormpdf(dmm, mu_bli, sigma_bli);
        else
            Lb = safeNormpdf(mu_bli, mu_bli, sigma_bli);
        end

        evi_dmm = Ls * prior_sac + Lb * prior_bli;
        if evi_dmm <= 0
            psn = psbn * 0.5;
            pbn = psbn * 0.5;
        else
            pbn = psbn * Lb * prior_bli / evi_dmm;
            psn = psbn * Ls * prior_sac / evi_dmm;
        end

        PFN(n) = pfn;
        PSN(n) = psn;
        PBN(n) = pbn;

        % ==========================================================
        % A) 扫视检测：saccade probability 最大的一段连续区间
        % ==========================================================
        if psn > pfn && psn > pbn
            if saccade_samples == 0
                sac_on_start_n = n;
            end
            saccade_on = true;
            saccade_samples = saccade_samples + 1;
            saccade_prob = saccade_prob + psn;

        elseif saccade_on
            % 一个扫视段结束，做事件级确认
            if saccade_prob > MIN_SACCADE_LEN * fs
                buffer_start = round(max(1, n - MAX_SACCADE_LEN * fs));
                if Nsacs > 0
                    buffer_start = round(max(buffer_start, ...
                        (SAC_START(end) + SAC_DUR(end)) * fs + groupDelay + 1));
                end

                buffer = ND2(buffer_start:n);
                [~, peak_in_buffer] = max(buffer);

                if peak_in_buffer == 1
                    peak_start_in_buffer = 1;
                else
                    peak_start_in_buffer = 1;
                    for k = peak_in_buffer-1 : -1 : 1
                        if buffer(k) - buffer(k+1) > 0
                            peak_start_in_buffer = k + 1;
                            break;
                        end
                    end
                end

                if peak_in_buffer == length(buffer)
                    peak_end_in_buffer = length(buffer);
                else
                    peak_end_in_buffer = length(buffer);
                    for k = peak_in_buffer+1 : length(buffer)
                        if buffer(k) - buffer(k-1) > 0
                            peak_end_in_buffer = k - 1;
                            break;
                        end
                    end
                end

                saccade_dur = peak_end_in_buffer - peak_start_in_buffer;
                saccade_start_n = buffer_start + peak_start_in_buffer - groupDelay - 1;
                saccade_prob_mass = sum(PSN(round(buffer_start + peak_start_in_buffer - 1):n), 'omitnan');

                saccade_ok = true;
                if saccade_prob_mass < MIN_SACCADE_LEN * fs
                    saccade_ok = false;
                end

                if Nblinks > 0
                    if saccade_start_n / fs < BLI_START(end) + BLI_DUR(end)
                        saccade_ok = false;
                    end
                end

                if Nsacs > 0
                    a = max(1, sac_on_end_prev_n);
                    b = max(a, min(N, sac_on_start_n));
                    if sum(PFN(a:b), 'omitnan') < MIN_SACCADE_GAP * fs
                        saccade_ok = false;
                    end
                    if (saccade_start_n / fs) - (SAC_START(end) + SAC_DUR(end)) < MIN_SACCADE_GAP
                        saccade_ok = false;
                    end
                end

                if saccade_ok
                    Nsacs = Nsacs + 1;
                    SAC_START(Nsacs,1) = saccade_start_n / fs; %#ok<AGROW>
                    SAC_DUR(Nsacs,1)   = saccade_dur / fs;     %#ok<AGROW>
                    SAC_PROB(Nsacs,1)  = saccade_prob / max(1, saccade_samples); %#ok<AGROW>
                    sac_on_end_prev_n = n;
                end
            end

            saccade_on = false;
            saccade_samples = 0;
            saccade_prob = 0;
        end

        % ==========================================================
        % B) 眨眼检测：blink probability 最大的一段连续区间
        % ==========================================================
        if pbn > pfn && pbn > psn
            blink_on = true;
            blink_samples = blink_samples + 1;
            blink_prob = blink_prob + pbn;

        elseif blink_on
            % 一个 blink 段结束，做事件级确认
            this_blink_peak = (peak_n - groupDelay) / fs;
            blink_ok = true;

            % 原始 detect-blink 思路：需要足够的概率质量
            if blink_prob < (MIN_BLINK_LEN / 4) * fs
                blink_ok = false;
            end

            if blink_ok
                buffer_start = round(max(1, n - MAX_BLINK_LEN * fs));
                if Nblinks > 0
                    buffer_start = round(max(buffer_start, ...
                        (BLI_START(end) + BLI_DUR(end)) * fs + groupDelay + 1));
                end

                % 这里沿用原始思路：用较高频带的垂直通道确定 blink 局部峰和持续时间
                buffer_diff = diff(vf_rec2(buffer_start:n));
                buffer_v = vf_rec2(buffer_start:n);

                if isempty(buffer_diff) || isempty(buffer_v)
                    blink_ok = false;
                else
                    [buffer_peak, peak_in_buffer] = max(buffer_diff);
                    [~, peak_in_buffer2] = max(buffer_v);

                    peak_start_in_buffer = peak_in_buffer;
                    for k = peak_in_buffer : -1 : 1
                        if buffer_diff(k) < 0.1 * buffer_peak
                            peak_start_in_buffer = k;
                            break;
                        end
                    end

                    % 原文假设 blink 峰近似对称，因此用 2 * 半宽估计总宽度
                    blink_dur = 2 * (peak_in_buffer2 - peak_start_in_buffer + 0.5);

                    if blink_dur > MIN_BLINK_LEN * fs
                        Nblinks = Nblinks + 1;
                        BLI_PEAK(Nblinks,1)  = this_blink_peak; %#ok<AGROW>
                        BLI_START(Nblinks,1) = (buffer_start + peak_start_in_buffer - groupDelay) / fs; %#ok<AGROW>
                        BLI_DUR(Nblinks,1)   = blink_dur / fs; %#ok<AGROW>
                        BLI_PROB(Nblinks,1)  = blink_prob / max(1, blink_samples); %#ok<AGROW>
                        BLI_DMM(Nblinks,1)   = max(DMM(max(1, n-10):n), [], 'omitnan'); %#ok<AGROW>
                    else
                        blink_ok = false;
                    end
                end

                % 原始逻辑：blink 常形成 sac-blink-sac 结构，
                % 因此前一个“扫视”有时是 blink 引起的伪边缘，要删掉
                if blink_ok && Nsacs > 0
                    if BLI_START(end) < SAC_START(end) + SAC_DUR(end)
                        SAC_START = SAC_START(1:end-1);
                        SAC_DUR   = SAC_DUR(1:end-1);
                        SAC_PROB  = SAC_PROB(1:end-1);
                        Nsacs     = Nsacs - 1;
                    end
                end
            end

            blink_on = false;
            blink_samples = 0;
            blink_prob = 0;
        end
    end

    % -------- 组织输出 --------
    result = struct();

    % 原始/中间信号
    result.h_filt1Hz  = hf_rec;
    result.v_filt1Hz  = vf_rec;
    result.h_filt40Hz = hf_rec2;
    result.v_filt40Hz = vf_rec2;
    result.Hd = Hd;
    result.Vd = Vd;
    result.Hd2 = Hd2;
    result.Vd2 = Vd2;
    result.ND = ND;
    result.ND2 = ND2;
    result.DMM = DMM;
    result.PFN = PFN;
    result.PSN = PSN;
    result.PBN = PBN;
    result.groupDelay = groupDelay;

    % 事件结果
    result.Nblinks = Nblinks;
    result.BLI_PEAK = BLI_PEAK;
    result.BLI_START = BLI_START;
    result.BLI_DUR = BLI_DUR;
    result.BLI_PROB = BLI_PROB;
    result.BLI_DMM = BLI_DMM;

    result.Nsacs = Nsacs;
    result.SAC_START = SAC_START;
    result.SAC_DUR = SAC_DUR;
    result.SAC_PROB = SAC_PROB;

    % 模型参数
    result.train_secs = train_secs;
    result.fs = fs;
    result.model.mu_fix = mu_fix;
    result.model.sigma_fix = sigma_fix;
    result.model.prior_fix = prior_fix;
    result.model.mu_bs = mu_bs;
    result.model.sigma_bs = sigma_bs;
    result.model.prior_bs = prior_bs;
    result.model.mu_sac = mu_sac;
    result.model.sigma_sac = sigma_sac;
    result.model.prior_sac = prior_sac;
    result.model.mu_bli = mu_bli;
    result.model.sigma_bli = sigma_bli;
    result.model.prior_bli = prior_bli;

    % 检测参数
    result.cfg = cfg;
end

%% =========================================================================
function blink_tbl = resultToBlinkTable(result, file_name, fs, n_samples, duration_s, train_secs, cfg)
    if result.Nblinks == 0
        blink_tbl = initBlinkEventTable();
        return;
    end

    n = result.Nblinks;
    BLI_END = result.BLI_START + result.BLI_DUR;
    BLI_PEAK_sample  = round(result.BLI_PEAK  * fs);
    BLI_START_sample = round(result.BLI_START * fs);
    BLI_END_sample   = round(BLI_END * fs);

    blink_tbl = table();
    blink_tbl.file_name         = repmat(string(file_name), n, 1);
    blink_tbl.blink_index       = (1:n).';
    blink_tbl.fs_Hz             = repmat(fs, n, 1);
    blink_tbl.n_samples         = repmat(n_samples, n, 1);
    blink_tbl.duration_total_s  = repmat(duration_s, n, 1);

    blink_tbl.BLI_PEAK_s        = result.BLI_PEAK(:);
    blink_tbl.BLI_START_s       = result.BLI_START(:);
    blink_tbl.BLI_DUR_s         = result.BLI_DUR(:);
    blink_tbl.BLI_END_s         = BLI_END(:);
    blink_tbl.BLI_PROB          = result.BLI_PROB(:);
    blink_tbl.BLI_DMM           = result.BLI_DMM(:);

    blink_tbl.BLI_PEAK_sample   = BLI_PEAK_sample(:);
    blink_tbl.BLI_START_sample  = BLI_START_sample(:);
    blink_tbl.BLI_END_sample    = BLI_END_sample(:);

    blink_tbl.train_secs        = repmat(train_secs, n, 1);
    blink_tbl.filtered_h_channel = repmat(cfg.filtered_h_ch, n, 1);
    blink_tbl.raw_h_channel      = repmat(cfg.raw_h_ch, n, 1);
    blink_tbl.filtered_v_channel = repmat(cfg.filtered_v_ch, n, 1);
    blink_tbl.raw_v_channel      = repmat(cfg.raw_v_ch, n, 1);

    blink_tbl.model_mu_fix      = repmat(result.model.mu_fix, n, 1);
    blink_tbl.model_mu_bs       = repmat(result.model.mu_bs, n, 1);
    blink_tbl.model_mu_sac      = repmat(result.model.mu_sac, n, 1);
    blink_tbl.model_mu_bli      = repmat(result.model.mu_bli, n, 1);

    blink_tbl.notes             = repmat("BLI_PEAK 为粗略峰时刻；BLI_START/BLI_DUR 更适合正式分析", n, 1);
end

%% =========================================================================
function sac_tbl = resultToSaccadeTable(result, file_name)
    if result.Nsacs == 0
        sac_tbl = initSaccadeEventTable();
        return;
    end

    n = result.Nsacs;
    sac_tbl = table();
    sac_tbl.file_name     = repmat(string(file_name), n, 1);
    sac_tbl.saccade_index = (1:n).';
    sac_tbl.SAC_START_s   = result.SAC_START(:);
    sac_tbl.SAC_DUR_s     = result.SAC_DUR(:);
    sac_tbl.SAC_END_s     = result.SAC_START(:) + result.SAC_DUR(:);
    sac_tbl.SAC_PROB      = result.SAC_PROB(:);
end

%% =========================================================================
function row = buildSummaryRow(result, file_name, fs, n_samples, duration_s, train_secs, meta, cfg, status_str, err_msg)
% buildSummaryRow
% 生成单个文件的汇总信息行
% 要求：initSummaryTable() 返回的表必须已经包含本函数中要写入的所有列

    % 先用统一模板初始化，保证每次返回的列完全一致
    row = initSummaryTable();

    % ===== 基本信息 =====
    row.file_name(1)    = string(file_name);
    row.status(1)       = string(status_str);
    row.error_message(1)= string(err_msg);

    row.fs_Hz(1)        = fs;
    row.n_samples(1)    = n_samples;
    row.duration_s(1)   = duration_s;
    row.train_secs(1)   = train_secs;

    % ===== 通道信息 =====
    row.filtered_h_channel(1) = cfg.filtered_h_ch;
    row.raw_h_channel(1)      = cfg.raw_h_ch;
    row.filtered_v_channel(1) = cfg.filtered_v_ch;
    row.raw_v_channel(1)      = cfg.raw_v_ch;

    % ===== 算法参数 =====
    row.MIN_SACCADE_GAP_s(1) = cfg.MIN_SACCADE_GAP;
    row.MIN_SACCADE_LEN_s(1) = cfg.MIN_SACCADE_LEN;
    row.MAX_SACCADE_LEN_s(1) = cfg.MAX_SACCADE_LEN;
    row.MIN_BLINK_LEN_s(1)   = cfg.MIN_BLINK_LEN;
    row.MAX_BLINK_LEN_s(1)   = cfg.MAX_BLINK_LEN;

    % ===== 数据变量名 =====
    if isstruct(meta) && isfield(meta, 'data_var_used')
        row.data_var_used(1) = string(meta.data_var_used);
    else
        row.data_var_used(1) = "";
    end

    % ===== 默认值：即使失败或无事件，也保持列完整 =====
    row.N_blinks(1)          = 0;
    row.N_saccades(1)        = 0;

    row.mean_BLI_DUR_s(1)    = NaN;
    row.median_BLI_DUR_s(1)  = NaN;
    row.mean_BLI_PROB(1)     = NaN;
    row.mean_BLI_DMM(1)      = NaN;
    row.median_BLI_DMM(1)    = NaN;

    row.mean_SAC_DUR_s(1)    = NaN;
    row.mean_SAC_PROB(1)     = NaN;

    row.first_BLI_START_s(1) = NaN;
    row.last_BLI_END_s(1)    = NaN;

    row.model_mu_fix(1)      = NaN;
    row.model_mu_bs(1)       = NaN;
    row.model_mu_sac(1)      = NaN;
    row.model_mu_bli(1)      = NaN;

    % ===== 如果 result 有效，再覆盖默认值 =====
    if isstruct(result)
        if isfield(result, 'Nblinks') && ~isempty(result.Nblinks)
            row.N_blinks(1) = result.Nblinks;
        end

        if isfield(result, 'Nsacs') && ~isempty(result.Nsacs)
            row.N_saccades(1) = result.Nsacs;
        end

        % ---- blink 汇总 ----
        if isfield(result, 'BLI_DUR') && ~isempty(result.BLI_DUR)
            row.mean_BLI_DUR_s(1)   = mean(result.BLI_DUR, 'omitnan');
            row.median_BLI_DUR_s(1) = median(result.BLI_DUR, 'omitnan');
        end

        if isfield(result, 'BLI_PROB') && ~isempty(result.BLI_PROB)
            row.mean_BLI_PROB(1) = mean(result.BLI_PROB, 'omitnan');
        end

        if isfield(result, 'BLI_DMM') && ~isempty(result.BLI_DMM)
            row.mean_BLI_DMM(1)   = mean(result.BLI_DMM, 'omitnan');
            row.median_BLI_DMM(1) = median(result.BLI_DMM, 'omitnan');
        end

        if isfield(result, 'BLI_START') && ~isempty(result.BLI_START)
            row.first_BLI_START_s(1) = result.BLI_START(1);

            if isfield(result, 'BLI_DUR') && numel(result.BLI_DUR) >= numel(result.BLI_START)
                row.last_BLI_END_s(1) = result.BLI_START(end) + result.BLI_DUR(end);
            end
        end

        % ---- saccade 汇总 ----
        if isfield(result, 'SAC_DUR') && ~isempty(result.SAC_DUR)
            row.mean_SAC_DUR_s(1) = mean(result.SAC_DUR, 'omitnan');
        end

        if isfield(result, 'SAC_PROB') && ~isempty(result.SAC_PROB)
            row.mean_SAC_PROB(1) = mean(result.SAC_PROB, 'omitnan');
        end

        % ---- 模型参数 ----
        if isfield(result, 'model') && isstruct(result.model)
            if isfield(result.model, 'mu_fix'), row.model_mu_fix(1) = result.model.mu_fix; end
            if isfield(result.model, 'mu_bs'),  row.model_mu_bs(1)  = result.model.mu_bs;  end
            if isfield(result.model, 'mu_sac'), row.model_mu_sac(1) = result.model.mu_sac; end
            if isfield(result.model, 'mu_bli'), row.model_mu_bli(1) = result.model.mu_bli; end
        end
    end
end

%% =========================================================================
function saveQCPlot(file_name, h_filt, v_filt, h_raw, v_raw, fs, result, qc_dir)
% 保存一张简单 QC 图：
%   上：滤波后的水平/垂直
%   下：blink probability + blink 区间
    t = (0:numel(h_filt)-1)' / fs;

    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1400 900]);

    subplot(3,1,1);
    plot(t, h_filt, 'b');
    hold on;
    plot(t, v_filt, 'r');
    xlabel('时间 / s'); ylabel('幅值');
    title(['滤波后 EOG（水平/垂直） - ' file_name], 'Interpreter', 'none');
    legend({'水平滤波通道(1轨)','垂直滤波通道(3轨)'}, 'Location', 'best');
    grid on;

    subplot(3,1,2);
    plot(t, h_raw, 'Color', [0.3 0.3 0.8]);
    hold on;
    plot(t, v_raw, 'Color', [0.8 0.3 0.3]);
    xlabel('时间 / s'); ylabel('幅值');
    title('原始 EOG（2轨/4轨）');
    legend({'水平原始通道(2轨)','垂直原始通道(4轨)'}, 'Location', 'best');
    grid on;

    subplot(3,1,3);
    plot(t, result.PFN, 'k');
    hold on;
    plot(t, result.PSN, 'g');
    plot(t, result.PBN, 'r');
    xlabel('时间 / s'); ylabel('概率');
    title('fixation / saccade / blink 概率');
    legend({'P(fixation)','P(saccade)','P(blink)'}, 'Location', 'best');
    ylim([0 1]);
    grid on;

    % 叠加 blink 区间
    for i = 1:result.Nblinks
        x1 = result.BLI_START(i);
        x2 = result.BLI_START(i) + result.BLI_DUR(i);
        patch([x1 x2 x2 x1], [0 0 1 1], [1 0.85 0.85], ...
            'FaceAlpha', 0.2, 'EdgeColor', 'none');
    end
    uistack(findobj(gca, 'Type', 'line'), 'top');

    saveas(fig, fullfile(qc_dir, [erase(file_name, '.mat') '_qc.png']));
    close(fig);
end

%% =========================================================================
function y = safeNormpdf(x, mu, sigma)
% 避免 sigma 过小导致数值问题
    sigma = max(double(sigma), eps);
    y = exp(-0.5 * ((double(x) - double(mu)) ./ sigma).^2) ./ (sqrt(2*pi) * sigma);
end

%% =========================================================================
function [mu, sigma, prior] = EMgauss1D(x, K)
% 简单 1D 高斯混合 EM，避免依赖额外工具箱
% 输入：
%   x: 列向量
%   K: 混合成分个数，这里固定为 2
    x = double(x(:));
    x = x(isfinite(x));

    if nargin < 2
        K = 2;
    end

    if numel(x) < K
        error('EMgauss1D 输入样本太少。');
    end

    % 初始化：按分位数
    qs = linspace(0, 1, K+2);
    qs = qs(2:end-1);
    mu = simpleQuantile(x, qs).';
    if numel(mu) < K
        mu = linspace(min(x), max(x), K).';
    end
    sigma = repmat(max(std(x), eps), K, 1);
    prior = repmat(1/K, K, 1);

    max_iter = 200;
    tol = 1e-6;
    prev_ll = -inf;

    for iter = 1:max_iter
        % E-step
        resp = zeros(numel(x), K);
        for k = 1:K
            resp(:,k) = prior(k) * safeNormpdf(x, mu(k), sigma(k));
        end
        denom = sum(resp, 2);
        denom(denom <= eps) = eps;
        resp = resp ./ denom;

        % M-step
        Nk = sum(resp, 1);
        Nk(Nk <= eps) = eps;

        for k = 1:K
            mu(k) = sum(resp(:,k) .* x) / Nk(k);
            var_k = sum(resp(:,k) .* (x - mu(k)).^2) / Nk(k);
            sigma(k) = sqrt(max(var_k, eps));
            prior(k) = Nk(k) / numel(x);
        end

        % 对数似然
        ll = sum(log(denom));
        if abs(ll - prev_ll) < tol
            break;
        end
        prev_ll = ll;
    end
end

%% =========================================================================

function q = simpleQuantile(x, probs)
% 基础分位数函数，避免依赖额外工具箱
    x = sort(x(:));
    n = numel(x);
    q = zeros(size(probs));
    for ii = 1:numel(probs)
        p = probs(ii);
        if p <= 0
            q(ii) = x(1);
        elseif p >= 1
            q(ii) = x(end);
        else
            pos = 1 + (n - 1) * p;
            lo = floor(pos);
            hi = ceil(pos);
            if lo == hi
                q(ii) = x(lo);
            else
                q(ii) = x(lo) + (pos - lo) * (x(hi) - x(lo));
            end
        end
    end
end

%% =========================================================================
function [mu2, sigma2, prior2] = sortGMM(mu, sigma, prior)
% 按均值从小到大排序，保持三个参数同步
    [mu2, idx] = sort(mu(:), 'ascend');
    sigma2 = sigma(idx);
    prior2 = prior(idx);
end

%% =========================================================================

function T = initBlinkEventTable()
    T = table();
    T.file_name = strings(0,1);
    T.blink_index = zeros(0,1);
    T.fs_Hz = zeros(0,1);
    T.n_samples = zeros(0,1);
    T.duration_total_s = zeros(0,1);
    T.BLI_PEAK_s = zeros(0,1);
    T.BLI_START_s = zeros(0,1);
    T.BLI_DUR_s = zeros(0,1);
    T.BLI_END_s = zeros(0,1);
    T.BLI_PROB = zeros(0,1);
    T.BLI_DMM = zeros(0,1);
    T.BLI_PEAK_sample = zeros(0,1);
    T.BLI_START_sample = zeros(0,1);
    T.BLI_END_sample = zeros(0,1);
    T.train_secs = zeros(0,1);
    T.filtered_h_channel = zeros(0,1);
    T.raw_h_channel = zeros(0,1);
    T.filtered_v_channel = zeros(0,1);
    T.raw_v_channel = zeros(0,1);
    T.model_mu_fix = zeros(0,1);
    T.model_mu_bs = zeros(0,1);
    T.model_mu_sac = zeros(0,1);
    T.model_mu_bli = zeros(0,1);
    T.notes = strings(0,1);
end

%% =========================================================================
function T = initSaccadeEventTable()
    T = table( ...
        strings(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
        'VariableNames', {'file_name','saccade_index','SAC_START_s','SAC_DUR_s','SAC_END_s','SAC_PROB'});
end

%% =========================================================================
function T = initSummaryTable()
% initSummaryTable
% 初始化 FileSummary 的空表模板
% 注意：这里的列名必须和 buildSummaryRow() 完全一致

    T = table();

    % ===== 基本信息 =====
    T.file_name         = strings(0,1);
    T.status            = strings(0,1);
    T.error_message     = strings(0,1);

    T.fs_Hz             = zeros(0,1);
    T.n_samples         = zeros(0,1);
    T.duration_s        = zeros(0,1);
    T.train_secs        = zeros(0,1);

    % ===== 通道信息 =====
    T.filtered_h_channel = zeros(0,1);
    T.raw_h_channel      = zeros(0,1);
    T.filtered_v_channel = zeros(0,1);
    T.raw_v_channel      = zeros(0,1);

    % ===== 事件数量 =====
    T.N_blinks          = zeros(0,1);
    T.N_saccades        = zeros(0,1);

    % ===== blink 汇总 =====
    T.mean_BLI_DUR_s    = zeros(0,1);
    T.median_BLI_DUR_s  = zeros(0,1);
    T.mean_BLI_PROB     = zeros(0,1);
    T.mean_BLI_DMM      = zeros(0,1);
    T.median_BLI_DMM    = zeros(0,1);
    T.first_BLI_START_s = zeros(0,1);
    T.last_BLI_END_s    = zeros(0,1);

    % ===== saccade 汇总 =====
    T.mean_SAC_DUR_s    = zeros(0,1);
    T.mean_SAC_PROB     = zeros(0,1);

    % ===== 算法参数 =====
    T.MIN_SACCADE_GAP_s = zeros(0,1);
    T.MIN_SACCADE_LEN_s = zeros(0,1);
    T.MAX_SACCADE_LEN_s = zeros(0,1);
    T.MIN_BLINK_LEN_s   = zeros(0,1);
    T.MAX_BLINK_LEN_s   = zeros(0,1);

    % ===== 元信息 =====
    T.data_var_used     = strings(0,1);

    % ===== 模型参数 =====
    T.model_mu_fix      = zeros(0,1);
    T.model_mu_bs       = zeros(0,1);
    T.model_mu_sac      = zeros(0,1);
    T.model_mu_bli      = zeros(0,1);
end 

%% =========================================================================
function T = buildFieldDescriptionTable()
    var_name = {
        'file_name'
        'blink_index'
        'BLI_PEAK_s'
        'BLI_START_s'
        'BLI_DUR_s'
        'BLI_END_s'
        'BLI_PROB'
        'BLI_DMM'
        'BLI_PEAK_sample'
        'BLI_START_sample'
        'BLI_END_sample'
        'SAC_START_s'
        'SAC_DUR_s'
        'SAC_END_s'
        'SAC_PROB'
        'N_blinks'
        'N_saccades'
        'mean_BLI_DUR_s'
        'mean_BLI_PROB'
        'median_BLI_DMM'
        'model_mu_fix'
        'model_mu_bs'
        'model_mu_sac'
        'model_mu_bli'
        'data_var_used'
        'status'
        'error_message'
        };

    meaning = {
        '原始 .mat 文件名'
        '该文件中第几个 blink'
        '眨眼峰值时刻（秒，原始算法中注明是粗略估计）'
        '眨眼开始时刻（秒，更适合正式分析）'
        '眨眼持续时间（秒）'
        '眨眼结束时刻（秒）'
        '该 blink 事件的平均 blink 概率'
        '用于 blink/saccade 区分的 dmm 特征强度'
        'BLI_PEAK 对应的样本点'
        'BLI_START 对应的样本点'
        'BLI_END 对应的样本点'
        '扫视开始时刻（秒）'
        '扫视持续时间（秒）'
        '扫视结束时刻（秒）'
        '该扫视事件的平均 saccade 概率'
        '该文件中识别出的 blink 总数'
        '该文件中识别出的 saccade 总数'
        '该文件 blink 平均持续时间'
        '该文件 blink 平均概率'
        '该文件 blink 的 BLI_DMM 中位数'
        'fixation 分布均值'
        'blink/saccade 混合分布均值'
        'saccade 分布均值'
        'blink 分布均值'
        '自动识别到的 .mat 数据变量名'
        '文件处理状态：成功/失败'
        '若失败，这里记录失败原因'
        };

    unit = {
        ''
        ''
        's'
        's'
        's'
        's'
        ''
        ''
        'sample'
        'sample'
        'sample'
        's'
        's'
        's'
        ''
        ''
        ''
        's'
        ''
        ''
        ''
        ''
        ''
        ''
        ''
        ''
        ''
        };

    T = table(string(var_name), string(meaning), string(unit), ...
        'VariableNames', {'field_name','meaning_cn','unit'});
end
