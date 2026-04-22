function export_blink_summary_from_total(inputXlsx, outputXlsx, train_secs, block_size_min)
% export_blink_summary_from_total
% 作用：
%   读取 total_AR_Blink.xlsx 中的 BlinkEvents 与 FileSummary，
%   输出一个“汇总表”Excel，包含：
%   1) SubjectSummary      —— 每个被试一行的总体汇总
%   2) MinuteSummary_Long  —— 每个被试每分钟一行（长表）
%   3) BlockSummary_5min   —— 每个被试每5分钟一行（块均值长表）
%
% 统计逻辑：
%   - 以 BLI_START_s 作为 blink 事件归属时间
%   - 默认去掉前 train_secs 秒训练段
%   - MinuteSummary_Long 中统计：
%       BLI_DMM_mean_min
%       BLI_DUR_mean_min
%       BLI_PROB_mean_min
%       BLI_TIME_count_min   （该分钟 blink 个数）
%   - BlockSummary_5min 中统计每 block_size_min 分钟的块均值
%
% 使用示例：
%   export_blink_summary_from_total
%
%   export_blink_summary_from_total( ...
%       'E:\AR_EOG\total\detect_blink_output\total_AR_Blink.xlsx', ...
%       'E:\AR_EOG\total\detect_blink_output\total_AR_Blink_summary.xlsx', ...
%       180, 5);

    %% =========================
    % 0. 默认参数
    %% =========================
    if nargin < 1 || isempty(inputXlsx)
        inputXlsx = 'E:\AR_EOG\test_detect_total\detect_blink_output_raw_60\total_AR_Blink_r6.xlsx';
    end

    if nargin < 2 || isempty(outputXlsx)
        [p, n, ~] = fileparts(inputXlsx);
        outputXlsx = fullfile(p, [n '_summary.xlsx']);
    end

    if nargin < 3 || isempty(train_secs)
        train_secs = 60;
    end

    if nargin < 4 || isempty(block_size_min)
        block_size_min = 5;
    end

    fprintf('=============================================\n');
    fprintf('开始导出 blink 汇总表\n');
    fprintf('输入文件：%s\n', inputXlsx);
    fprintf('输出文件：%s\n', outputXlsx);
    fprintf('训练段：%.1f s\n', train_secs);
    fprintf('块大小：%d min\n', block_size_min);
    fprintf('=============================================\n');

    %% =========================
    % 1. 读取数据
    %% =========================
    Tblink = readtable(inputXlsx, 'Sheet', 'BlinkEvents');

    Tsum = table();
    try
        Tsum = readtable(inputXlsx, 'Sheet', 'FileSummary');
    catch
        % 若没有 FileSummary，则后面根据事件末端估计时长
    end

    needVars = {'file_name','BLI_START_s','BLI_DUR_s','BLI_PROB','BLI_DMM'};
    checkVarsExist(Tblink, needVars, 'BlinkEvents');

    files = unique(Tblink.file_name, 'stable');

    SubjectSummary = table();
    MinuteSummary_Long = table();
    BlockSummary = table();

    %% =========================
    % 2. 逐被试统计
    %% =========================
    for i = 1:numel(files)
        thisFile = files{i};
        idx = strcmp(Tblink.file_name, thisFile);
        Tb = Tblink(idx, :);

        [subjID, subjName] = parseSubjectName(thisFile);

        duration_s = getDurationForFile(thisFile, Tb, Tsum);
        effective_dur_s = max(duration_s - train_secs, 0);
        effective_dur_min = effective_dur_s / 60;

        % 去掉训练段
        Tb2 = Tb(Tb.BLI_START_s >= train_secs, :);

        % ---------- 每分钟长表 ----------
        nFullMinutes = floor(effective_dur_s / 60);

        minuteRows = table();
        if nFullMinutes > 0
            minuteRows = table();
            minuteRows.subject_id = strings(0,1);
            minuteRows.subject_name = strings(0,1);
            minuteRows.file_name = strings(0,1);
            minuteRows.minute_index = zeros(0,1);
            minuteRows.minute_start_s = zeros(0,1);
            minuteRows.minute_end_s = zeros(0,1);
            minuteRows.BLI_DMM_mean_min = zeros(0,1);
            minuteRows.BLI_DUR_mean_min = zeros(0,1);
            minuteRows.BLI_PROB_mean_min = zeros(0,1);
            minuteRows.BLI_TIME_count_min = zeros(0,1);

            for m = 1:nFullMinutes
                t0 = train_secs + (m-1)*60;
                t1 = t0 + 60;

                idm = Tb.BLI_START_s >= t0 & Tb.BLI_START_s < t1;
                Tm = Tb(idm, :);

                r = table();
                r.subject_id = string(subjID);
                r.subject_name = string(subjName);
                r.file_name = string(thisFile);
                r.minute_index = m;
                r.minute_start_s = t0;
                r.minute_end_s = t1;

                if ~isempty(Tm)
                    r.BLI_DMM_mean_min = mean(Tm.BLI_DMM, 'omitnan');
                    r.BLI_DUR_mean_min = mean(Tm.BLI_DUR_s, 'omitnan');
                    r.BLI_PROB_mean_min = mean(Tm.BLI_PROB, 'omitnan');
                    r.BLI_TIME_count_min = height(Tm);
                else
                    r.BLI_DMM_mean_min = NaN;
                    r.BLI_DUR_mean_min = NaN;
                    r.BLI_PROB_mean_min = NaN;
                    r.BLI_TIME_count_min = 0;
                end

                minuteRows = [minuteRows; r];
            end
        end

        % ---------- 5分钟块长表 ----------
        blockRows = table();
        if ~isempty(minuteRows)
            nBlocks = ceil(height(minuteRows) / block_size_min);

            blockRows = table();
            blockRows.subject_id = strings(0,1);
            blockRows.subject_name = strings(0,1);
            blockRows.file_name = strings(0,1);
            blockRows.block_index = zeros(0,1);
            blockRows.block_start_min = zeros(0,1);
            blockRows.block_end_min = zeros(0,1);
            blockRows.BLI_DMM_mean_block = zeros(0,1);
            blockRows.BLI_DUR_mean_block = zeros(0,1);
            blockRows.BLI_PROB_mean_block = zeros(0,1);
            blockRows.BLI_TIME_mean_block = zeros(0,1);
            blockRows.BLI_TIME_sum_block = zeros(0,1);

            for b = 1:nBlocks
                s = (b-1)*block_size_min + 1;
                e = min(b*block_size_min, height(minuteRows));

                Tblk = minuteRows(s:e, :);

                r = table();
                r.subject_id = string(subjID);
                r.subject_name = string(subjName);
                r.file_name = string(thisFile);
                r.block_index = b;
                r.block_start_min = Tblk.minute_index(1);
                r.block_end_min = Tblk.minute_index(end);

                r.BLI_DMM_mean_block = mean(Tblk.BLI_DMM_mean_min, 'omitnan');
                r.BLI_DUR_mean_block = mean(Tblk.BLI_DUR_mean_min, 'omitnan');
                r.BLI_PROB_mean_block = mean(Tblk.BLI_PROB_mean_min, 'omitnan');
                r.BLI_TIME_mean_block = mean(Tblk.BLI_TIME_count_min, 'omitnan');
                r.BLI_TIME_sum_block = sum(Tblk.BLI_TIME_count_min, 'omitnan');

                blockRows = [blockRows; r];
            end
        end

        % ---------- 每个被试一行总体汇总 ----------
        srow = table();
        srow.subject_id = string(subjID);
        srow.subject_name = string(subjName);
        srow.file_name = string(thisFile);
        srow.duration_s = duration_s;
        srow.train_secs = train_secs;
        srow.effective_duration_min = effective_dur_min;
        srow.N_blinks_after_train = height(Tb2);

        if effective_dur_min > 0
            srow.blink_rate_per_min_after_train = height(Tb2) / effective_dur_min;
        else
            srow.blink_rate_per_min_after_train = NaN;
        end

        if ~isempty(Tb2)
            srow.mean_BLI_DMM = mean(Tb2.BLI_DMM, 'omitnan');
            srow.mean_BLI_DUR_s = mean(Tb2.BLI_DUR_s, 'omitnan');
            srow.mean_BLI_PROB = mean(Tb2.BLI_PROB, 'omitnan');
            srow.median_BLI_DMM = median(Tb2.BLI_DMM, 'omitnan');
            srow.median_BLI_DUR_s = median(Tb2.BLI_DUR_s, 'omitnan');
            srow.first_BLI_START_s_after_train = min(Tb2.BLI_START_s);
            srow.last_BLI_START_s_after_train = max(Tb2.BLI_START_s);
        else
            srow.mean_BLI_DMM = NaN;
            srow.mean_BLI_DUR_s = NaN;
            srow.mean_BLI_PROB = NaN;
            srow.median_BLI_DMM = NaN;
            srow.median_BLI_DUR_s = NaN;
            srow.first_BLI_START_s_after_train = NaN;
            srow.last_BLI_START_s_after_train = NaN;
        end

        SubjectSummary = [SubjectSummary; srow];
        MinuteSummary_Long = [MinuteSummary_Long; minuteRows];
        BlockSummary = [BlockSummary; blockRows];
    end

    %% =========================
    % 3. 说明表
    %% =========================
    Tdesc = buildDescriptionTable();

    %% =========================
    % 4. 写出 Excel
    %% =========================
    if exist(outputXlsx, 'file')
        delete(outputXlsx);
    end

    writetable(SubjectSummary, outputXlsx, 'Sheet', 'SubjectSummary');
    writetable(MinuteSummary_Long, outputXlsx, 'Sheet', 'MinuteSummary_Long');
    writetable(BlockSummary, outputXlsx, 'Sheet', 'BlockSummary_5min');
    writetable(Tdesc, outputXlsx, 'Sheet', '说明');

    fprintf('=============================================\n');
    fprintf('汇总表导出完成。\n');
    fprintf('输出文件：%s\n', outputXlsx);
    fprintf('=============================================\n');
end


%% =========================================================
function [subjID, subjName] = parseSubjectName(fileName)
% 从 "P0-liuyepeng.mat" 提取 P0 和 liuyepeng

    [~, base, ~] = fileparts(fileName);
    parts = split(string(base), '-');

    if numel(parts) >= 2
        subjID = char(parts(1));
        subjName = char(parts(2));
    else
        subjID = char(base);
        subjName = '';
    end
end


%% =========================================================
function duration_s = getDurationForFile(thisFile, Tb, Tsum)
% 优先从 FileSummary 读取总时长；若无，则从事件末端估计

    duration_s = NaN;

    if ~isempty(Tsum) && ...
       any(strcmp(Tsum.Properties.VariableNames, 'file_name')) && ...
       any(strcmp(Tsum.Properties.VariableNames, 'duration_s'))

        idx = strcmp(Tsum.file_name, thisFile);
        if any(idx)
            duration_s = Tsum.duration_s(find(idx, 1, 'first'));
        end
    end

    if ~(isfinite(duration_s) && duration_s > 0)
        if ~isempty(Tb)
            duration_s = max(Tb.BLI_START_s + Tb.BLI_DUR_s);
        else
            duration_s = 0;
        end
    end
end


%% =========================================================
function checkVarsExist(T, needVars, sheetName)
% 检查表中是否存在所需字段

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
        'SubjectSummary.N_blinks_after_train'
        'SubjectSummary.blink_rate_per_min_after_train'
        'SubjectSummary.mean_BLI_DMM'
        'SubjectSummary.mean_BLI_DUR_s'
        'SubjectSummary.mean_BLI_PROB'
        'MinuteSummary_Long.minute_index'
        'MinuteSummary_Long.BLI_DMM_mean_min'
        'MinuteSummary_Long.BLI_DUR_mean_min'
        'MinuteSummary_Long.BLI_PROB_mean_min'
        'MinuteSummary_Long.BLI_TIME_count_min'
        'BlockSummary_5min.block_index'
        'BlockSummary_5min.BLI_DMM_mean_block'
        'BlockSummary_5min.BLI_DUR_mean_block'
        'BlockSummary_5min.BLI_PROB_mean_block'
        'BlockSummary_5min.BLI_TIME_mean_block'
        'BlockSummary_5min.BLI_TIME_sum_block'
        };

    meaning_cn = {
        '去掉训练段后该被试的 blink 总数'
        '去掉训练段后该被试每分钟 blink 率'
        '去掉训练段后该被试 BLI_DMM 总体均值'
        '去掉训练段后该被试 BLI_DUR 总体均值（秒）'
        '去掉训练段后该被试 BLI_PROB 总体均值'
        '第几个有效分钟，从1开始'
        '该分钟内 blink 的 BLI_DMM 均值'
        '该分钟内 blink 的 BLI_DUR 均值'
        '该分钟内 blink 的 BLI_PROB 均值'
        '该分钟内 blink 个数'
        '第几个 5 分钟块，从1开始'
        '该 5 分钟块内各分钟 BLI_DMM 均值的平均值'
        '该 5 分钟块内各分钟 BLI_DUR 均值的平均值'
        '该 5 分钟块内各分钟 BLI_PROB 均值的平均值'
        '该 5 分钟块内各分钟 blink 个数的平均值'
        '该 5 分钟块内 blink 总个数'
        };

    unit = {
        'count'
        'count/min'
        'DMM'
        's'
        'prob'
        'min'
        'DMM'
        's'
        'prob'
        'count'
        'block'
        'DMM'
        's'
        'prob'
        'count/min'
        'count/block'
        };

    Tdesc = table(field_name, meaning_cn, unit);
end
