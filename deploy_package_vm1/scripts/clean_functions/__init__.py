import os
import importlib

# 取得當前資料夾路徑
_current_dir = os.path.dirname(__file__)

__all__ = []

# 掃描資料夾內所有的 .py 檔案
for _filename in os.listdir(_current_dir):
    # 略過 __init__.py 與非 python 檔
    if _filename.endswith(".py") and not _filename.startswith("__"):
        _module_name = _filename[:-3]
        
        # 動態載入該檔案 (例如 get_data.py)
        _module = importlib.import_module(f".{_module_name}", package=__name__)
        
        # 把檔案裡面不是以 _ 開頭的函數全部抓出來
        for _attr_name in dir(_module):
            if not _attr_name.startswith("_"):
                # 將函數掛載到這個資料夾的命名空間下
                globals()[_attr_name] = getattr(_module, _attr_name)
                __all__.append(_attr_name)
