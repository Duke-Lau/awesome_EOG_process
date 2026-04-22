function plot_vertical_eog_with_blinks(matFile, xlsxFile, tStart, tEnd)
% plot_vertical_eog_with_blinks
% 功能：
%   读取 BIOPAC Acq 导出的 .mat 文件中的垂直眼电（当前按第3列）
%   再读取 detect-blink 输出的 xlsx 中 BlinkEvents 工作表
%   将垂直眼电波形 + blink 起止点 画在同一张图上
%
% 使用方式：
%   1) 直接运行（使用默认路径和默认时间窗）
%      plot_vertical_eog_with_blinks
%
%   2) 自定义路径
%      plot_vertical_eog_with_blinks(matFile, xlsxFile, tStart, tEnd)

    %% =========================
    %  0. 默认路径与默认时间窗
    %% =========================
    if nargin < 1 || isempty(matFile)
        matFile = 'C:\Users\cnis-\Desktop\AR_EOG\P4\P4-dengaiteng.mat';
    end

    if nargin < 2 || isempty(xlsxFile)
        xlsxFile = 'C:\Users\cnis-\Desktop\AR_EOG\P4\detect_blink_output\P4-dengaiteng.xlsx';
    end

    if nargin < 3 || isempty(tStart)
        tStart = 180;
    end

    if nargin < 4 || isempty(tEnd)
        tEnd = 240;
    end

    %% =========================
    %  1. 参数区（按你当前文件结构设置）
    %% =========================
    dataVarName = 'data';   % .mat 中主数据矩阵变量名
    vCol = 3;               % 垂直眼电所在列：你当前是第3列
    blinkSheet = 'BlinkEvents';

    %% =========================
    %  2. 读取 mat 数据
    %% =========================
    S = load(matFile);

    if ~isfield(S, dataVarName)
        error('在 mat 文件中未找到变量 "%s"。', dataVarName);
    end

    X = S.(dataVarName);

    if size(X,2) < vCol
        error('数据列数不足，无法读取第 %d 列垂直眼电。', vCol);
    end

    % 垂直眼电波形
    vEOG = double(X(:, vCol));

    %% =========================
    %  3. 识别采样率 fs
    %% =========================
    fs = [];

    % 优先读取 excel 里写出的 fs_Hz
    try
        Tblink_all = readtable(xlsxFile, 'Sheet', blinkSheet);
        if any(strcmp(Tblink_all.Properties.VariableNames, 'fs_Hz'))
            fs_tmp = Tblink_all.fs_Hz(1);
            if ~isempty(fs_tmp) && isfinite(fs_tmp) && fs_tmp > 0
                fs = fs_tmp;
            end
        end
    catch
        % 如果读失败，后面再从 mat 里尝试
    end

    % 如果 excel 没拿到，就从 mat 里找
    if isempty(fs)
        if isfield(S, 'fs') && isscalar(S.fs)
            fs = double(S.fs);
        elseif isfield(S, 'Fs') && isscalar(S.Fs)
            fs = double(S.Fs);
        elseif isfield(S, 'isi') && isscalar(S.isi)
            % 若有 isi 和 isi_units，则尽量按单位推断
            if isfield(S, 'isi_units')
                unitStr = lower(strtrim(string(S.isi_units)));
                if contains(unitStr, "ms")
                    fs = 1000 / double(S.isi);
                elseif contains(unitStr, "us") || contains(unitStr, "μs") || contains(unitStr, "micro")
                    fs = 1e6 / double(S.isi);
                else
                    fs = 1 / double(S.isi);
                end
            else
                % 没单位时用经验规则
                if S.isi < 1
                    fs = 1 / double(S.isi);
                else
                    fs = 1000 / double(S.isi);
                end
            end
        else
            error('无法自动识别采样率 fs，请检查 mat 或 xlsx。');
        end
    end

    %% =========================
    %  4. 读取 blink 事件表
    %% =========================
    Tblink = readtable(xlsxFile, 'Sheet', blinkSheet);

    % 检查关键列是否存在
    needCols = {'BLI_START_s','BLI_END_s'};
    for i = 1:numel(needCols)
        if ~any(strcmp(Tblink.Properties.VariableNames, needCols{i}))
            error('BlinkEvents 工作表中缺少字段：%s', needCols{i});
        end
    end

    % 如果表里有 file_name，就只保留当前 mat 文件对应的事件
    if any(strcmp(Tblink.Properties.VariableNames, 'file_name'))
        [~, matName, ext] = fileparts(matFile);
        thisFileName = [matName ext];
        Tblink = Tblink(strcmp(Tblink.file_name, thisFileName), :);
    end

    %% =========================
    %  5. 根据时间窗截取波形
    %% =========================
    n = length(vEOG);
    totalDur = (n - 1) / fs;

    tStart = max(0, tStart);
    tEnd   = min(totalDur, tEnd);

    if tEnd <= tStart
        error('时间窗无效：tEnd 必须大于 tStart。');
    end

    idx1 = max(1, floor(tStart * fs) + 1);
    idx2 = min(n, ceil(tEnd * fs) + 1);

    t = ((idx1:idx2) - 1) ./ fs;
    y = vEOG(idx1:idx2);

    %% =========================
    %  6. 只保留当前时间窗内的 blink
    %% =========================
    blinkMask = Tblink.BLI_END_s >= tStart & Tblink.BLI_START_s <= tEnd;
    Tb = Tblink(blinkMask, :);

    %% =========================
    %  7. 作图
    %% =========================
    figure('Color','w','Name','垂直眼电 + blink 起止点');
    plot(t, y, 'b-', 'LineWidth', 0.8);
    hold on;

    yl = ylim;

    % --- 用浅红色阴影标出 blink 区间 ---
    for i = 1:height(Tb)
        xs = max(Tb.BLI_START_s(i), tStart);
        xe = min(Tb.BLI_END_s(i),   tEnd);

        patch( ...
            [xs xe xe xs], ...
            [yl(1) yl(1) yl(2) yl(2)], ...
            [1 0.85 0.85], ...
            'EdgeColor', 'none', ...
            'FaceAlpha', 0.25);
    end

    % 阴影加完后重画波形
    plot(t, y, 'b-', 'LineWidth', 0.8);

    % --- 画 blink 起点、终点竖线 ---
    for i = 1:height(Tb)
        xs = Tb.BLI_START_s(i);
        xe = Tb.BLI_END_s(i);

        if xs >= tStart && xs <= tEnd
            xline(xs, 'g--', 'LineWidth', 1.0); % 起点
        end
        if xe >= tStart && xe <= tEnd
            xline(xe, 'r--', 'LineWidth', 1.0); % 终点
        end
    end

    % --- 如果有峰值时刻，也画出来 ---
    if any(strcmp(Tb.Properties.VariableNames, 'BLI_PEAK_s'))
        for i = 1:height(Tb)
            xp = Tb.BLI_PEAK_s(i);
            if xp >= tStart && xp <= tEnd
                xline(xp, 'k:', 'LineWidth', 0.8); % 峰值
            end
        end
    end

    %% =========================
    %  8. 图形标注
    %% =========================
    title(sprintf('垂直眼电波形 + detect-blink 结果  [%.2f s, %.2f s]', tStart, tEnd), ...
        'FontWeight', 'bold');
    xlabel('时间 / s');
    ylabel('垂直眼电幅值');
    grid on;
    box on;

    legend({'垂直眼电','blink区间','blink起点','blink终点','blink峰值'}, ...
        'Location','best');

    txt = sprintf('当前窗口内 blink 数 = %d', height(Tb));
    text(tStart + 0.01*(tEnd-tStart), yl(2) - 0.08*(yl(2)-yl(1)), txt, ...
        'FontSize', 10, 'FontWeight', 'bold', 'BackgroundColor', 'w');

    hold off;

    %% =========================
    %  9. 命令行输出
    %% =========================
    fprintf('---------------------------------------------\n');
    fprintf('文件：%s\n', matFile);
    fprintf('采样率 fs = %.3f Hz\n', fs);
    fprintf('绘图时间窗：%.3f ~ %.3f s\n', tStart, tEnd);
    fprintf('当前窗口内 blink 数：%d\n', height(Tb));
    if height(Tb) > 0
        fprintf('第一个 blink：start = %.3f s, end = %.3f s, dur = %.3f s\n', ...
            Tb.BLI_START_s(1), Tb.BLI_END_s(1), Tb.BLI_DUR_s(1));
    end
    fprintf('---------------------------------------------\n');

end