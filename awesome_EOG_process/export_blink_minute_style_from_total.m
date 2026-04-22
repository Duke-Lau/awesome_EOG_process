function export_blink_minute_style_from_total(inputXlsx, outputDir, train_secs, block_size_min)
% export_blink_minute_style_from_total
% 作用：
%   读取 total_AR_Blink.xlsx 中的 BlinkEvents 和 FileSummary，
%   以 BLI_START_s 为归属时间，将 blink 事件按“分钟”汇总，
%   并按你上传示例的样式，为每个被试分别导出一个 xlsx 文件。
%
% 输出表结构（与示例风格一致）：
%   A: 被试ID
%   B: 姓名
%   C: 留空
%   D: BLI_DMM（每分钟均值）
%   E: 该 5 分钟块的 BLI_DMM 均值（只填在每个 5 分钟块的第一行）
%   F: BLI_DUR（每分钟均值）
%   G: 该 5 分钟块的 BLI_DUR 均值（只填在每个 5 分钟块的第一行）
%   H: BLI_PROB（每分钟均值）
%   I: BLI_TIME（每分钟 blink 个数）
%   J: 该 5 分钟块的 BLI_TIME 均值（只填在每个 5 分钟块的第一行）
%
% 使用示例：
%   export_blink_minute_style_from_total
%
%   export_blink_minute_style_from_total( ...
%       'E:\AR_EOG\total\detect_blink_output\total_AR_Blink.xlsx', ...
%       'E:\AR_EOG\total\detect_blink_output\minute_style_output', ...
%       180, 5);

    %% =========================
    % 0. 默认参数
    %% =========================
    if nargin < 1 || isempty(inputXlsx)
        inputXlsx = 'E:\AR_EOG\test_detect_total\detect_blink_output_raw_60\total_AR_Blink_r6.xlsx';
    end

    if nargin < 2 || isempty(outputDir)
        [p,~,~] = fileparts(inputXlsx);
        outputDir = fullfile(p, 'minute_style_output');
    end

    if nargin < 3 || isempty(train_secs)
        train_secs = 60;   % 前 180 s 为训练段，默认不纳入分钟统计
    end

    if nargin < 4 || isempty(block_size_min)
        block_size_min = 5; % 每 5 分钟做一次块均值
    end

    if ~exist(outputDir, 'dir')
        mkdir(outputDir);
    end

    fprintf('=============================================\n');
    fprintf('开始按“每分钟统计 + 每5分钟块均值”的样式导出 blink Excel\n');
    fprintf('输入文件：%s\n', inputXlsx);
    fprintf('输出目录：%s\n', outputDir);
    fprintf('训练段：%.1f s\n', train_secs);
    fprintf('块大小：%d min\n', block_size_min);
    fprintf('=============================================\n');

    %% =========================
    % 1. 读取工作表
    %% =========================
    Tblink = readtable(inputXlsx, 'Sheet', 'BlinkEvents');

    Tsum = table();
    try
        Tsum = readtable(inputXlsx, 'Sheet', 'FileSummary');
    catch
        % 若没有 FileSummary，则后面用事件末端估计时长
    end

    needVars = {'file_name','BLI_START_s','BLI_DUR_s','BLI_PROB','BLI_DMM'};
    checkVarsExist(Tblink, needVars, 'BlinkEvents');

    files = unique(Tblink.file_name, 'stable');

    %% =========================
    % 2. 逐被试导出
    %% =========================
    for i = 1:numel(files)
        thisFile = files{i};
        idx = strcmp(Tblink.file_name, thisFile);
        Tb = Tblink(idx, :);

        [subjID, subjName] = parseSubjectName(thisFile);

        % ---- 获取总时长 ----
        duration_s = getDurationForFile(thisFile, Tb, Tsum);

        % ---- 去掉训练段，按整分钟统计 ----
        effectiveDur = duration_s - train_secs;
        nFullMinutes = floor(effectiveDur / 60);

        if nFullMinutes <= 0
            fprintf('[%d/%d] %s：有效时长不足 1 分钟，跳过。\n', i, numel(files), thisFile);
            continue;
        end

        out = cell(nFullMinutes + 1, 10);

        % 表头：尽量贴近你上传示例
        out(1,:) = {'被试ID', '姓名', '', 'BLI_DMM', '', 'BLI_DUR', '', 'BLI_PROB', 'BLI_TIME', ''};

        minuteDMM  = NaN(nFullMinutes,1);
        minuteDUR  = NaN(nFullMinutes,1);
        minutePROB = NaN(nFullMinutes,1);
        minuteCNT  = NaN(nFullMinutes,1);

        % ---- 逐分钟统计 ----
        for m = 1:nFullMinutes
            t0 = train_secs + (m-1)*60;
            t1 = t0 + 60;

            idm = Tb.BLI_START_s >= t0 & Tb.BLI_START_s < t1;
            Tm = Tb(idm, :);

            out{m+1, 1} = subjID;
            out{m+1, 2} = subjName;
            out{m+1, 3} = '';

            if ~isempty(Tm)
                minuteDMM(m)  = mean(Tm.BLI_DMM, 'omitnan');
                minuteDUR(m)  = mean(Tm.BLI_DUR_s, 'omitnan');
                minutePROB(m) = mean(Tm.BLI_PROB, 'omitnan');
                minuteCNT(m)  = height(Tm);
            else
                minuteDMM(m)  = NaN;
                minuteDUR(m)  = NaN;
                minutePROB(m) = NaN;
                minuteCNT(m)  = 0;
            end

            % D/F/H/I 列：每分钟值
            out{m+1, 4} = minuteDMM(m)*1000;
            out{m+1, 5} = [];   % E：后面填 5 分钟块均值
            out{m+1, 6} = minuteDUR(m)*1000;
            out{m+1, 7} = [];   % G：后面填 5 分钟块均值
            out{m+1, 8} = minutePROB(m);
            out{m+1, 9} = minuteCNT(m);
            out{m+1,10} = [];   % J：后面填 5 分钟块均值
        end

        % ---- 每 5 分钟块均值：只填在每个块的第一行 ----
        for s = 1:block_size_min:nFullMinutes
            e = min(s + block_size_min - 1, nFullMinutes);

            out{s+1, 5}  = mean(minuteDMM(s:e),  'omitnan');
            out{s+1, 7}  = mean(minuteDUR(s:e),  'omitnan');
            out{s+1,10}  = mean(minuteCNT(s:e),  'omitnan');
        end

        % ---- 写出 ----
        outFile = fullfile(outputDir, sprintf('%s-%s.xlsx', subjID, subjName));

        % 若已有旧文件，先删掉
        if exist(outFile, 'file')
            delete(outFile);
        end

        writecell(out, outFile, 'Sheet', 'Sheet1', 'Range', 'A1');

        % ---- 简单格式化（可选）----
        % 这里用 xlswrite 风格的最稳方案，仅写数据，不强依赖 ActiveX。
        fprintf('[%d/%d] 已导出：%s\n', i, numel(files), outFile);
    end

    fprintf('=============================================\n');
    fprintf('全部导出完成。\n');
    fprintf('输出目录：%s\n', outputDir);
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
% 优先从 FileSummary 里读取总时长；若无，则从事件末端估计

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
