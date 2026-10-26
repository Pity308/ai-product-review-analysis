# -*- coding: utf-8 -*-
"""抓取 AI 产品 App Store（中国区）用户评论。
数据源：苹果官方公开评论接口（RSS/JSON），非爬虫、无需登录。
输出：ai_app_reviews.csv（UTF-8-BOM，可直接用 Excel/Navicat 打开）
"""
import os
import time

import pandas as pd
import requests

# 7 个目标 AI 产品（备份候选：讯飞星火 6449919551）
APPS = {
    "豆包": 6459478672,
    "DeepSeek": 6737597349,
    "文心一言": 6446882473,
    "Kimi": 6474233312,
    "通义千问": 6466733523,
    "腾讯元宝": 6480446430,
    "智谱清言": 6450893458,
}

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(BASE, "ai_app_reviews.csv")

rows = []
for app, app_id in APPS.items():
    got = 0
    for page in range(1, 11):  # 每个 App 最多 10 页，每页 50 条
        url = (
            f"https://itunes.apple.com/cn/rss/customerreviews/"
            f"page={page}/id={app_id}/sortBy=mostRecent/json"
        )
        try:
            feed = requests.get(url, timeout=15).json().get("feed", {})
        except Exception as e:
            print(f"[{app}] 第{page}页请求失败: {e}")
            break
        entries = feed.get("entry", [])
        if not isinstance(entries, list):
            break  # 没有更多评论
        for e in entries:
            if "im:rating" not in e:
                continue  # 跳过 App 信息条目
            rows.append({
                "app": app,
                "rating": int(e["im:rating"]["label"]),
                "version": e["im:version"]["label"],
                "time": e["updated"]["label"],
                "title": e["title"]["label"],
                "content": e["content"]["label"],
                "author": e["author"]["name"]["label"],
                "votes": int(e.get("im:voteCount", {}).get("label", 0)),
            })
            got += 1
        time.sleep(0.5)  # 礼貌间隔
    print(f"[{app}] 共获取 {got} 条")

df = pd.DataFrame(rows).drop_duplicates(subset=["app", "time", "content"])
df.to_csv(OUT, index=False, encoding="utf-8-sig")

print("\n===== 数据概览 =====")
print(f"总计 {len(df)} 条，已保存: {OUT}")
print(f"时间范围: {df['time'].min()} ~ {df['time'].max()}")
print("\n各产品统计:")
print(df.groupby("app")["rating"].agg(条数="count", 平均分="mean", 最低="min", 最高="max").round(2))
