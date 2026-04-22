function convert_detect_blink_excel_sec_to_min(inputXlsx, outputXlsx)
% convert_detect_blink_excel_sec_to_min
% 作用：
%   读取 detect-blink 输出的 Excel，
%   将事件先按“秒”聚合，再将每秒结果按“分钟”求均值，
%   最后输出新的 Excel。
%
% 适配当前表结构：
%   BlinkEvents
%   SaccadeEvents
%   FileSummary
%
% 使用示例：
%   convert_detect_blink_excel_sec_to_min
%
%   convert_detect_blink_excel_sec_to_min( ...
%       'E:\AR_EOG\total\detect_blink_output\total_AR_Blink.xlsx', ...
%       'E:\AR_EOG\total\detect_blink_output\total_AR_Blink_per_min.xlsx');

    %% =========================
    % 0. 默认路径
    %% =========================
    if nargin < 1 || isempty(inputXlsx)
        inputXlsx = 'E:\AR_EOG\total\detect_blink_output\total_AR_Blink.xlsx';
    end

    if nargin < 2 || isempty(outputXlsx)
        [p, n, ~] = fileparts(inputXlsx);
        outputXlsx = fullfile(p, [n '_per_min.xlsx']);
    end

    fprintf('=============================================\n');
    fprintf('开始将 detect-blink Excel 从“秒级”汇总为“分钟级”\n');
    fprintf('输入文件：%s\n', inputXlsx);
    fprintf('输出文件：%s\n', outputXlsx);
    fprintf('=============================================\n');

    %% =========================
    % 1. 读取工作表
    %% =========================
    Tblink = table();
    Tsac   = table();
    Tsum   = table();

    try
        Tblink = readtable(inputXlsx, 'Sheet', 'BlinkEvents');
        fprintf('已读取工作表：BlinkEvents\n');
    catch
        warning('未读取到 BlinkEvents 工作表。');
    end

    try
        Tsac = readtable(inputXlsx, 'Sheet', 'SaccadeEvents');
        fprintf('已读取工作表：SaccadeEvents\n');
    catch
        warning('未读取到 SaccadeEvents 工作表。');
    end

    try
        Tsum = readtable(inputXlsx, 'Sheet', 'FileSummary');
        fprintf('已读取工作表：FileSummary\n');
    catch
        warning('未读取到 FileSummary 工作表。');
    end

    %% =========================
    % 2. Blink：按秒聚合，再按分钟求均值
    %% =========================
    BlinkPerSecond = table();
    BlinkPerMinute = table();

    if ~isempty(Tblink)
        BlinkPerSecond = buildBlinkPerSecond(Tblink, Tsum);
        BlinkPerMinute = buildBlinkPerMinute(BlinkPerSecond);
        fprintf('Blink 已完成秒级与分钟级统计。\n');
    end

    %% =========================
    % 3. Saccade：按秒聚合，再按分钟求均值
    %% =========================
    SaccadePerSecond = table();
    SaccadePerMinute = table();

    if ~isempty(Tsac)
        SaccadePerSecond = buildSaccadePerSecond(Tsac, Tsum);
        SaccadePerMinute = buildSaccadePerMinute(SaccadePerSecond);
        fprintf('Saccade 已完成秒级与分钟级统计。\n');
    end

    %% =========================
    % 4. 写出到新的 Excel
    %% =========================
    if exist(outputXlsx, 'file')
        delete(outputXlsx);
    end

    if ~isempty(BlinkPerSecond)
        writetable(BlinkPerSecond, outputXlsx, 'Sheet', 'BlinkPerSecond');
    end

    if ~isempty(BlinkPerMinute)
        writetable(BlinkPerMinute, outputXlsx, 'Sheet', 'BlinkPerMinute');
    end

    if ~isempty(SaccadePerSecond)
        writetable(SaccadePerSecond, outputXlsx, 'Sheet', 'SaccadePerSecond');
    end

    if ~isempty(SaccadePerMinute)
        writetable(SaccadePerMinute, outputXlsx, 'Sheet', 'SaccadePerMinute');
    end

    if ~isempty(Tsum)
        writetable(Tsum, outputXlsx, 'Sheet', 'FileSummary_Original');
    end

    Tdesc = buildDescriptionTable();
    writetable(Tdesc, outputXlsx, 'Sheet', '说明');

    fprintf('=============================================\n');
    fprintf('处理完成。\n');
    fprintf('输出文件：%s\n', outputXlsx);
    fprintf('=============================================\n');
end


%% =========================================================
function Tsec = buildBlinkPerSecond(Tblink, Tsum)
% 将 BlinkEvents 聚合成每秒一行

    needVars = {'file_name','BLI_START_s','BLI_DUR_s','BLI_PROB','BLI_DMM'};
    checkVarsExist(Tblink, needVars, 'BlinkEvents');

    allRows = table();

    files = unique(Tblink.file_name, 'stable');

    for i = 1:numel(files)
        thisFile = files{i};
        idx = strcmp(Tblink.file_name, thisFile);
        Tb = Tblink(idx, :);

        % 总时长优先从 FileSummary 里取
        duration_s = getDurationForFile(thisFile, Tb, Tsum, 'BLI_START_s', 'BLI_DUR_s');

        % 秒索引：第 0 秒、第 1 秒……
        sec_idx = floor(Tb.BLI_START_s);
        maxSec = max(ceil(duration_s), 1);

        secGrid = (0:maxSec-1)';
        nSec = numel(secGrid);

        out = table();
        out.file_name = repmat(string(thisFile), nSec, 1);
        out.second_index = secGrid;
        out.second_start_s = secGrid;
        out.second_end_s = secGrid + 1;
        out.minute_index = floor(secGrid / 60);

        % 默认值
        out.blink_count_sec = zeros(nSec, 1);
        out.BLI_DUR_mean_sec = NaN(nSec, 1);
        out.BLI_PROB_mean_sec = NaN(nSec, 1);
        out.BLI_DMM_mean_sec = NaN(nSec, 1);

        % 只保留有效秒索引
        valid = sec_idx >= 0 & sec_idx < maxSec;
        sec_idx = sec_idx(valid);
        Tb = Tb(valid, :);

        if ~isempty(Tb)
            [G, secVals] = findgroups(sec_idx);

            count_sec = splitapply(@numel, Tb.BLI_START_s, G);
            dur_sec   = splitapply(@(x) mean(x, 'omitnan'), Tb.BLI_DUR_s, G);
            prob_sec  = splitapply(@(x) mean(x, 'omitnan'), Tb.BLI_PROB, G);
            dmm_sec   = splitapply(@(x) mean(x, 'omitnan'), Tb.BLI_DMM, G);

            mapIdx = secVals + 1; % 因为 sec=0 对应第1行
            out.blink_count_sec(mapIdx) = count_sec;
            out.BLI_DUR_mean_sec(mapIdx) = dur_sec;
            out.BLI_PROB_mean_sec(mapIdx) = prob_sec;
            out.BLI_DMM_mean_sec(mapIdx) = dmm_sec;
        end

        allRows = [allRows; out];
    end

    Tsec = allRows;
end


%% =========================================================
function Tmin = buildBlinkPerMinute(Tsec)
% 根据 BlinkPerSecond 计算 BlinkPerMinute

    allRows = table();
    files = unique(Tsec.file_name, 'stable');

    for i = 1:numel(files)
        thisFile = files(i);
        Ts = Tsec(Tsec.file_name == thisFile, :);

        minuteVals = unique(Ts.minute_index, 'stable');
        nMin = numel(minuteVals);

        out = table();
        out.file_name = repmat(thisFile, nMin, 1);
        out.minute_index = minuteVals;
        out.minute_start_s = minuteVals * 60;
        out.minute_end_s = (minuteVals + 1) * 60;

        out.blink_count_sec_mean_in_min = NaN(nMin,1);
        out.blink_count_total_in_min = NaN(nMin,1);
        out.BLI_DUR_sec_mean_in_min = NaN(nMin,1);
        out.BLI_PROB_sec_mean_in_min = NaN(nMin,1);
        out.BLI_DMM_sec_mean_in_min = NaN(nMin,1);

        for k = 1:nMin
            idx = Ts.minute_index == minuteVals(k);
            Tm = Ts(idx, :);

            out.blink_count_sec_mean_in_min(k) = mean(Tm.blink_count_sec, 'omitnan');
            out.blink_count_total_in_min(k)    = sum(Tm.blink_count_sec, 'omitnan');
            out.BLI_DUR_sec_mean_in_min(k)     = mean(Tm.BLI_DUR_mean_sec, 'omitnan');
            out.BLI_PROB_sec_mean_in_min(k)    = mean(Tm.BLI_PROB_mean_sec, 'omitnan');
            out.BLI_DMM_sec_mean_in_min(k)     = mean(Tm.BLI_DMM_mean_sec, 'omitnan');
        end

        allRows = [allRows; out];
    end

    Tmin = allRows;
end


%% =========================================================
function Tsec = buildSaccadePerSecond(Tsac, Tsum)
% 将 SaccadeEvents 聚合成每秒一行

    needVars = {'file_name','SAC_START_s','SAC_DUR_s','SAC_PROB'};
    checkVarsExist(Tsac, needVars, 'SaccadeEvents');

    allRows = table();
    files = unique(Tsac.file_name, 'stable');

    for i = 1:numel(files)
        thisFile = files{i};
        idx = strcmp(Tsac.file_name, thisFile);
        Ts = Tsac(idx, :);

        duration_s = getDurationForFile(thisFile, Ts, Tsum, 'SAC_START_s', 'SAC_DUR_s');

        sec_idx = floor(Ts.SAC_START_s);
        maxSec = max(ceil(duration_s), 1);

        secGrid = (0:maxSec-1)';
        nSec = numel(secGrid);

        out = table();
        out.file_name = repmat(string(thisFile), nSec, 1);
        out.second_index = secGrid;
        out.second_start_s = secGrid;
        out.second_end_s = secGrid + 1;
        out.minute_index = floor(secGrid / 60);

        out.saccade_count_sec = zeros(nSec, 1);
        out.SAC_DUR_mean_sec = NaN(nSec, 1);
        out.SAC_PROB_mean_sec = NaN(nSec, 1);

        valid = sec_idx >= 0 & sec_idx < maxSec;
        sec_idx = sec_idx(valid);
        Ts = Ts(valid, :);

        if ~isempty(Ts)
            [G, secVals] = findgroups(sec_idx);

            count_sec = splitapply(@numel, Ts.SAC_START_s, G);
            dur_sec   = splitapply(@(x) mean(x, 'omitnan'), Ts.SAC_DUR_s, G);
            prob_sec  = splitapply(@(x) mean(x, 'omitnan'), Ts.SAC_PROB, G);

            mapIdx = secVals + 1;
            out.saccade_count_sec(mapIdx) = count_sec;
            out.SAC_DUR_mean_sec(mapIdx) = dur_sec;
            out.SAC_PROB_mean_sec(mapIdx) = prob_sec;
        end

        allRows = [allRows; out];
    end

    Tsec = allRows;
end


%% =========================================================
function Tmin = buildSaccadePerMinute(Tsec)
% 根据 SaccadePerSecond 计算 SaccadePerMinute

    allRows = table();
    files = unique(Tsec.file_name, 'stable');

    for i = 1:numel(files)
        thisFile = files(i);
        Ts = Tsec(Tsec.file_name == thisFile, :);

        minuteVals = unique(Ts.minute_index, 'stable');
        nMin = numel(minuteVals);

        out = table();
        out.file_name = repmat(thisFile, nMin, 1);
        out.minute_index = minuteVals;
        out.minute_start_s = minuteVals * 60;
        out.minute_end_s = (minuteVals + 1) * 60;

        out.saccade_count_sec_mean_in_min = NaN(nMin,1);
        out.saccade_count_total_in_min = NaN(nMin,1);
        out.SAC_DUR_sec_mean_in_min = NaN(nMin,1);
        out.SAC_PROB_sec_mean_in_min = NaN(nMin,1);

        for k = 1:nMin
            idx = Ts.minute_index == minuteVals(k);
            Tm = Ts(idx, :);

            out.saccade_count_sec_mean_in_min(k) = mean(Tm.saccade_count_sec, 'omitnan');
            out.saccade_count_total_in_min(k)    = sum(Tm.saccade_count_sec, 'omitnan');
            out.SAC_DUR_sec_mean_in_min(k)       = mean(Tm.SAC_DUR_mean_sec, 'omitnan');
            out.SAC_PROB_sec_mean_in_min(k)      = mean(Tm.SAC_PROB_mean_sec, 'omitnan');
        end

        allRows = [allRows; out];
    end

    Tmin = allRows;
end


%% =========================================================
function duration_s = getDurationForFile(thisFile, Tevent, Tsum, startVar, durVar)
% 优先从 FileSummary 读取 duration_s
% 若没有，再从事件末端估计

    duration_s = NaN;

    if ~isempty(Tsum) && any(strcmp(Tsum.Properties.VariableNames, 'file_name')) ...
                     && any(strcmp(Tsum.Properties.VariableNames, 'duration_s'))
        idx = strcmp(Tsum.file_name, thisFile);
        if any(idx)
            duration_s = Tsum.duration_s(find(idx,1,'first'));
        end
    end

    if ~(isfinite(duration_s) && duration_s > 0)
        if ~isempty(Tevent) && any(strcmp(Tevent.Properties.VariableNames, startVar)) ...
                            && any(strcmp(Tevent.Properties.VariableNames, durVar))
            duration_s = max(Tevent.(startVar) + Tevent.(durVar));
        else
            duration_s = 0;
        end
    end
end


%% =========================================================
function checkVarsExist(T, needVars, sheetName)
% 检查表中是否存在所需列名

    vars = T.Properties.VariableNames;
    miss = needVars(~ismember(needVars, vars));

    if ~isempty(miss)
        error('工作表 %s 缺少字段：%s', sheetName, strjoin(miss, ', '));
    end
end


%% =========================================================
function Tdesc = buildDescriptionTable()
% 输出说明表

    field_name = {
        'BlinkPerSecond.second_index'
        'BlinkPerSecond.blink_count_sec'
        'BlinkPerSecond.BLI_DUR_mean_sec'
        'BlinkPerSecond.BLI_PROB_mean_sec'
        'BlinkPerSecond.BLI_DMM_mean_sec'
        'BlinkPerMinute.blink_count_sec_mean_in_min'
        'BlinkPerMinute.blink_count_total_in_min'
        'BlinkPerMinute.BLI_DUR_sec_mean_in_min'
        'BlinkPerMinute.BLI_PROB_sec_mean_in_min'
        'BlinkPerMinute.BLI_DMM_sec_mean_in_min'
        'SaccadePerSecond.saccade_count_sec'
        'SaccadePerSecond.SAC_DUR_mean_sec'
        'SaccadePerSecond.SAC_PROB_mean_sec'
        'SaccadePerMinute.saccade_count_sec_mean_in_min'
        'SaccadePerMinute.saccade_count_total_in_min'
        'SaccadePerMinute.SAC_DUR_sec_mean_in_min'
        'SaccadePerMinute.SAC_PROB_sec_mean_in_min'
        };

    meaning_cn = {
        '第几秒，从0开始'
        '这一秒内检测到的 blink 个数'
        '这一秒内 blink 持续时间均值'
        '这一秒内 blink 概率均值'
        '这一秒内 blink DMM 均值'
        '这一分钟内，每秒 blink 个数的均值'
        '这一分钟内 blink 总个数'
        '这一分钟内，每秒 blink 持续时间均值的平均值'
        '这一分钟内，每秒 blink 概率均值的平均值'
        '这一分钟内，每秒 blink DMM 均值的平均值'
        '这一秒内检测到的 saccade 个数'
        '这一秒内 saccade 持续时间均值'
        '这一秒内 saccade 概率均值'
        '这一分钟内，每秒 saccade 个数的均值'
        '这一分钟内 saccade 总个数'
        '这一分钟内，每秒 saccade 持续时间均值的平均值'
        '这一分钟内，每秒 saccade 概率均值的平均值'
        };

    unit = {
        's'
        'count'
        's'
        'prob'
        'DMM'
        'count/s'
        'count/min'
        's'
        'prob'
        'DMM'
        'count'
        's'
        'prob'
        'count/s'
        'count/min'
        's'
        'prob'
        };

    Tdesc = table(field_name, meaning_cn, unit);
end