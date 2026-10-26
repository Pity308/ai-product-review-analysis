# -*- coding: utf-8 -*-
"""把 ai_app_reviews.csv 导入 MySQL。
数据库: ai_reviews / 表: reviews_raw（原始表，保持原样不清洗，清洗留给 SQL 做）
"""
import os

import pandas as pd
from sqlalchemy import create_engine

BASE = os.path.dirname(os.path.abspath(__file__))
CSV = os.path.join(BASE, "ai_app_reviews.csv")

# 1. 建库（不存在才建）
server = create_engine("mysql+pymysql://root@localhost:3306/?charset=utf8mb4")
with server.connect() as conn:
    conn.exec_driver_sql(
        "CREATE DATABASE IF NOT EXISTS ai_reviews "
        "CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"
    )

# 2. 读 CSV，原样导入
df = pd.read_csv(CSV)
db = create_engine("mysql+pymysql://root@localhost:3306/ai_reviews?charset=utf8mb4")
df.to_sql("reviews_raw", db, if_exists="replace", index=False)

# 3. 验证
print("导入完成，各产品条数：")
check = pd.read_sql(
    "SELECT app, COUNT(*) AS cnt, ROUND(AVG(rating), 2) AS avg_rating "
    "FROM reviews_raw GROUP BY app ORDER BY cnt DESC",
    db,
)
print(check.to_string(index=False))
total = pd.read_sql("SELECT COUNT(*) AS n FROM reviews_raw", db)["n"][0]
print(f"\n总计 {int(total)} 条，已入库: ai_reviews.reviews_raw")
