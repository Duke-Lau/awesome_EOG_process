function run_all_detect_blink_pipeline()
% run_all_detect_blink_pipeline
% 总启动脚本：
%   第一步：运行 run_total_detect_blink_once.m / run_biopac_mp160_detect_blink_batch.m
%   第二步：运行 export_blink_minute_style_from_total.m
%   第三步：运行 export_blink_summary_from_total.m
%
% 使用方式：
%   1) 将本脚本与你的其他 .m 文件放在同一工作目录下
%   2) 在 MATLAB 命令行输入：
%         run_all_detect_blink_pipeline
%
% 注意：
%   - 若 run_total_detect_blink_once.m 已经写好了输入目录，则优先调用它
%   - 若没有该脚本，则直接调用 run_biopac_mp160_detect_blink_batch.m
%   - 请确保以下函数已存在于 MATLAB 路径中：
%       run_total_detect_blink_once.m
%       run_biopac_mp160_detect_blink_batch.m
%       export_blink_minute_style_from_total.m
%       export_blink_summary_from_total.m

    clc;
    close all;

    %% =========================
    % 0. 用户可修改参数区
    %% =========================
    % 原始总目录（存放 .mat 文件）
    input_dir = 'E:\AR_EOG\total';

    % detect-blink 输出目录
    detect_output_dir = fullfile(input_dir, 'detect_blink_output');

    % 第一步生成的总表 Excel
    total_xlsx = fullfile(detect_output_dir, 'total_AR_Blink.xlsx');

    % 第二步：逐被试“分钟样式”输出目录
    minute_style_output_dir = fullfile(detect_output_dir, 'minute_style_output');

    % 第三步：总体汇总表输出路径
    summary_xlsx = fullfile(detect_output_dir, 'total_AR_Blink_summary.xlsx');

    % 参数：训练段秒数
    train_secs = 180;

    % 参数：块均值窗口（分钟）
    block_size_min = 5;

    %% =========================
    % 1. 基本检查
    %% =========================
    fprintf('=============================================\n');
    fprintf('开始运行 detect-blink 全流程总启动脚本\n');
    fprintf('输入目录：%s\n', input_dir);
    fprintf('detect 输出目录：%s\n', detect_output_dir);
    fprintf('总表 Excel：%s\n', total_xlsx);
    fprintf('分钟样式输出目录：%s\n', minute_style_output_dir);
    fprintf('汇总表 Excel：%s\n', summary_xlsx);
    fprintf('训练段：%.1f s\n', train_secs);
    fprintf('块大小：%d min\n', block_size_min);
    fprintf('=============================================\n');

    if ~exist(input_dir, 'dir')
        error('输入目录不存在：%s', input_dir);
    end

    %% =========================
    % 2. 第一步：跑 detect-blink 主流程
    %% =========================
    fprintf('\n========== 第一步：运行 detect-blink 主流程 ==========\n');

    % 优先调用你已经写好的启动脚本
    if exist('run_total_detect_blink_once.m', 'file') == 2 || exist('run_total_detect_blink_once', 'file') == 2
        fprintf('检测到 run_total_detect_blink_once.m，优先调用该脚本。\n');
        run_total_detect_blink_once;
    else
        fprintf('未检测到 run_total_detect_blink_once.m，改为直接调用 run_biopac_mp160_detect_blink_batch。\n');

        if ~(exist('run_biopac_mp160_detect_blink_batch.m', 'file') == 2 || exist('run_biopac_mp160_detect_blink_batch', 'file') == 2)
            error('未找到 run_biopac_mp160_detect_blink_batch.m');
        end

        run_biopac_mp160_detect_blink_batch(input_dir);
    end

    if ~exist(total_xlsx, 'file')
        error('第一步完成后，未找到总表 Excel：%s', total_xlsx);
    end

    fprintf('第一步完成：已生成总表 Excel。\n');

    %% =========================
    % 3. 第二步：导出逐被试分钟样式表
    %% =========================
    fprintf('\n========== 第二步：导出逐被试分钟样式表 ==========\n');

    if ~(exist('export_blink_minute_style_from_total.m', 'file') == 2 || exist('export_blink_minute_style_from_total', 'file') == 2)
        error('未找到 export_blink_minute_style_from_total.m');
    end

    export_blink_minute_style_from_total( ...
        total_xlsx, ...
        minute_style_output_dir, ...
        train_secs, ...
        block_size_min);

    fprintf('第二步完成：已导出逐被试分钟样式表。\n');

    %% =========================
    % 4. 第三步：导出总体汇总表
    %% =========================
    fprintf('\n========== 第三步：导出总体汇总表 ==========\n');

    if ~(exist('export_blink_summary_from_total.m', 'file') == 2 || exist('export_blink_summary_from_total', 'file') == 2)
        error('未找到 export_blink_summary_from_total.m');
    end

    export_blink_summary_from_total( ...
        total_xlsx, ...
        summary_xlsx, ...
        train_secs, ...
        block_size_min);

    fprintf('第三步完成：已导出总体汇总表。\n');

    %% =========================
    % 5. 结束提示
    %% =========================
    fprintf('\n=============================================\n');
    fprintf('全流程执行完成。\n');
    fprintf('1) detect-blink 总表：%s\n', total_xlsx);
    fprintf('2) 分钟样式输出目录：%s\n', minute_style_output_dir);
    fprintf('3) 总体汇总表：%s\n', summary_xlsx);
    fprintf('=============================================\n');

end
