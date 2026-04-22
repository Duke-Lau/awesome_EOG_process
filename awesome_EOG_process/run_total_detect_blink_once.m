clc;
clear;
close all;

% ====== 你要处理的总目录 ======
input_dir = 'E:\AR_EOG\test_detect_total';

% ====== 运行主程序 ======
run_biopac_mp160_detect_blink_batch(input_dir);