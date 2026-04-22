import pandas as pd
from pathlib import Path
import re

def merge_excel_directory(input_dir: str, output_file: str, sheet_index: int = 0) -> None:
    """
    合并指定目录下的所有 Excel 文件至单一工作簿。
    
    :param input_dir: 待合并 Excel 文件所在目录路径
    :param output_file: 合并后输出的 Excel 文件名
    :param sheet_index: 需合并的工作表索引（0 表示第一个工作表）
    """
    input_path = Path(input_dir)
    if not input_path.is_dir():
        raise FileNotFoundError(f"错误：指定的输入路径不存在或不是有效目录 -> {input_dir}")

    def subject_sort_key(file_path: Path):
        """按文件名中的被试编号排序，如 P2 < P10。"""
        match = re.search(r'(?i)\bP(\d+)\b', file_path.stem)
        subject_id = int(match.group(1)) if match else float('inf')
        return (subject_id, file_path.name.lower())

    # 检索所有 .xlsx 文件，并排除即将生成的输出文件
    output_name_only = Path(output_file).name
    excel_files = sorted(
        [f for f in input_path.glob('*.xlsx') if f.name != output_name_only],
        key=subject_sort_key
    )
    # 若需支持 .xls 格式，可追加: + [f for f in input_path.glob('*.xls') if f.name != output_file]

    if not excel_files:
        print("提示：指定目录下未找到可合并的 Excel 文件。")
        return

    data_frames = []
    for file_path in excel_files:
        try:
            df = pd.read_excel(file_path, sheet_name=sheet_index)
            df['源文件名'] = file_path.name  # 添加数据来源标识列，便于后续核对
            data_frames.append(df)
            print(f"已读取: {file_path.name}")
        except Exception as e:
            print(f"警告：读取文件 {file_path.name} 时发生异常 -> {e}")

    if not data_frames:
        print("提示：未能成功解析任何有效数据表。")
        return

    # 纵向拼接数据表
    merged_df = pd.concat(data_frames, ignore_index=True)
    
    # 导出合并结果
    merged_df.to_excel(output_file, index=False)
    print(f"合并已完成。结果已保存至: {output_file}")

if __name__ == "__main__":
    # ================= 配置区 =================
    INPUT_FOLDER = r"E:\26.04.09-灯具测试-EOG\mat-total\detect_blink_output\minute_style_output"          # 请替换为实际文件夹路径（相对或绝对路径均可）
    OUTPUT_NAME = r"E:\26.04.09-灯具测试-EOG\mat-total\detect_blink_output\total_light_EOG.xlsx"     # 请指定输出文件名
    SHEET_INDEX = 0                        # 0 表示读取每个文件的第一个工作表
    # ==========================================
    
    merge_excel_directory(INPUT_FOLDER, OUTPUT_NAME, SHEET_INDEX)