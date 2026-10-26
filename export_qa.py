# -*- coding: utf-8 -*-
"""导出人工抽检表。

- qa_sample_30.csv：随机 30 条，用于估计整体准确率
- qa_hard_cases_20.csv：低置信度 + 评分/情感冲突，用于找系统性问题

人工只需填写 human_sentiment / human_issue / human_correct / human_notes。
"""
import os

import pandas as pd
import pymysql

BASE = os.path.dirname(os.path.abspath(__file__))
OUT_RANDOM = os.path.join(BASE, "qa_sample_30.csv")
OUT_HARD = os.path.join(BASE, "qa_hard_cases_20.csv")

BASE_SQL = """
SELECT
  review_id,
  app_name,
  rating,
  content,
  sentiment,
  issue_category,
  severity,
  is_actionable,
  confidence,
  key_quote
FROM v_labeled_reviews
"""


def query(sql):
    conn = pymysql.connect(
        host="localhost",
        user="root",
        password="",
        database="ai_reviews",
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
    )
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
            return pd.DataFrame(cur.fetchall())
    finally:
        conn.close()


def add_blank_columns(df):
    df = df.copy()
    df["human_sentiment"] = ""
    df["human_issue"] = ""
    df["human_correct"] = ""
    df["human_notes"] = ""
    return df[[
        "review_id", "app_name", "rating", "content",
        "human_sentiment", "human_issue", "human_correct", "human_notes",
        "sentiment", "issue_category", "severity", "is_actionable",
        "confidence", "key_quote",
    ]]


def main():
    # 按情感分层：负面 12 + 正面 12 + 中性 6，避免随机抽样漏掉中性样本
    neg = query(BASE_SQL + " WHERE sentiment = 'negative' ORDER BY RAND(20261020) LIMIT 12")
    pos = query(BASE_SQL + " WHERE sentiment = 'positive' ORDER BY RAND(20261021) LIMIT 12")
    neu = query(BASE_SQL + " WHERE sentiment = 'neutral'  ORDER BY RAND(20261022) LIMIT 6")
    random_df = pd.concat([neg, pos, neu], ignore_index=True)
    hard_df = query(
        BASE_SQL
        + """
        WHERE confidence < 0.7
           OR (rating >= 4 AND sentiment = 'negative')
           OR (rating <= 2 AND sentiment = 'positive')
        ORDER BY confidence ASC
        LIMIT 20
        """
    )

    add_blank_columns(random_df).to_csv(OUT_RANDOM, index=False, encoding="utf-8-sig")
    add_blank_columns(hard_df).to_csv(OUT_HARD, index=False, encoding="utf-8-sig")

    print(f"随机抽检: {len(random_df)} 条 -> {OUT_RANDOM}")
    print(f"困难样本: {len(hard_df)} 条 -> {OUT_HARD}")


if __name__ == "__main__":
    main()
