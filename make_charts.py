# -*- coding: utf-8 -*-
"""生成报告用图表，输出到 charts/ 目录。"""
import os

import matplotlib.pyplot as plt
import pandas as pd
import pymysql

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei"]
plt.rcParams["axes.unicode_minus"] = False

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(BASE, "charts")
os.makedirs(OUT, exist_ok=True)

POS = "#5CB85C"
NEU = "#F0AD4E"
NEG = "#D9534F"


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


def chart_sentiment_by_app():
    df = query("SELECT app_name, sentiment, pct FROM ads_app_sentiment")
    piv = (
        df.pivot(index="app_name", columns="sentiment", values="pct")
        .apply(pd.to_numeric, errors="coerce")
        .fillna(0)
    )
    for col in ("positive", "neutral", "negative"):
        if col not in piv.columns:
            piv[col] = 0
    order = query(
        "SELECT app_name FROM ads_app_label_overview ORDER BY negative_rate DESC"
    )["app_name"]
    piv = piv.reindex(order)[["positive", "neutral", "negative"]]

    fig, ax = plt.subplots(figsize=(10, 6))
    piv.plot(
        kind="barh", stacked=True, ax=ax,
        color=[POS, NEU, NEG], width=0.65,
        edgecolor="white", linewidth=0.8,
    )
    ax.set_xlim(0, 100)
    ax.set_xlabel("占比（%）")
    ax.set_ylabel("")
    ax.set_title("各产品情感分布（文本样本 n=2902）", fontsize=14, pad=12)
    ax.legend(["正面", "中性", "负面"], loc="lower right", frameon=False)
    ax.grid(axis="x", alpha=0.25)
    ax.set_axisbelow(True)

    for i, (idx, row) in enumerate(piv.iterrows()):
        left = 0
        for col in ("positive", "neutral", "negative"):
            val = row[col]
            if val >= 8:
                ax.text(
                    left + val / 2, i, f"{val:.1f}%",
                    ha="center", va="center", fontsize=8, color="white",
                )
            left += val

    plt.tight_layout()
    path = os.path.join(OUT, "sentiment_by_app.png")
    fig.savefig(path, dpi=160, bbox_inches="tight")
    plt.close(fig)


def chart_issue_distribution():
    df = query(
        """
        SELECT issue_category, COUNT(*) AS n
        FROM v_labeled_reviews
        WHERE sentiment = 'negative'
          AND issue_category <> '其他'
        GROUP BY issue_category
        ORDER BY n
        """
    )
    df["n"] = pd.to_numeric(df["n"], errors="coerce").fillna(0).astype(int)
    total = df["n"].sum()
    fig, ax = plt.subplots(figsize=(9, 5.5))
    bars = ax.barh(df["issue_category"], df["n"], color=NEG, alpha=0.85)
    ax.set_xlabel("负面评论条数")
    ax.set_title("负面评论的问题类型分布（排除“其他”）", fontsize=14, pad=12)
    ax.grid(axis="x", alpha=0.25)
    ax.set_axisbelow(True)

    for bar, (_, row) in zip(bars, df.iterrows()):
        ax.text(
            bar.get_width() + 4, bar.get_y() + bar.get_height() / 2,
            f"{int(row['n'])} ({row['n'] / total * 100:.1f}%)",
            va="center", fontsize=9,
        )
    ax.set_xlim(0, df["n"].max() * 1.18)
    plt.tight_layout()
    path = os.path.join(OUT, "issue_distribution.png")
    fig.savefig(path, dpi=160, bbox_inches="tight")
    plt.close(fig)


def chart_issue_heatmap():
    df = query(
        """
        SELECT app_name, issue_category, COUNT(*) AS n
        FROM v_labeled_reviews
        WHERE sentiment = 'negative'
          AND issue_category <> '其他'
        GROUP BY app_name, issue_category
        """
    )
    piv = (
        df.pivot(index="app_name", columns="issue_category", values="n")
        .apply(pd.to_numeric, errors="coerce")
        .fillna(0)
    )
    app_order = query(
        "SELECT app_name FROM ads_app_label_overview ORDER BY negative_rate DESC"
    )["app_name"]
    issue_order = (
        df.groupby("issue_category")["n"].sum().sort_values(ascending=False).index
    )
    piv = piv.reindex(index=app_order, columns=issue_order).fillna(0)

    fig, ax = plt.subplots(figsize=(11, 5.8))
    im = ax.imshow(piv.values, cmap="Reds", aspect="auto")
    ax.set_xticks(range(len(piv.columns)))
    ax.set_xticklabels(piv.columns, rotation=30, ha="right")
    ax.set_yticks(range(len(piv.index)))
    ax.set_yticklabels(piv.index)
    ax.set_title("各产品负面问题分布（条数）", fontsize=14, pad=12)

    for i in range(len(piv.index)):
        for j in range(len(piv.columns)):
            val = int(piv.values[i, j])
            if val:
                ax.text(
                    j, i, val, ha="center", va="center", fontsize=9,
                    color="white" if val > piv.values.max() * 0.55 else "#333333",
                )
    fig.colorbar(im, ax=ax, fraction=0.025, pad=0.02, label="条数")
    plt.tight_layout()
    path = os.path.join(OUT, "issue_heatmap.png")
    fig.savefig(path, dpi=160, bbox_inches="tight")
    plt.close(fig)


def chart_rating_vs_sentiment():
    df = (
        query(
            """
            SELECT
              rating,
              SUM(sentiment = 'positive') AS positive,
              SUM(sentiment = 'neutral')  AS neutral,
              SUM(sentiment = 'negative') AS negative
            FROM v_labeled_reviews
            GROUP BY rating
            ORDER BY rating
            """
        )
        .set_index("rating")
        .apply(pd.to_numeric, errors="coerce")
        .fillna(0)
    )
    fig, ax = plt.subplots(figsize=(8, 4.8))
    df.plot(
        kind="bar", stacked=True, ax=ax,
        color=[POS, NEU, NEG], width=0.65,
        edgecolor="white", linewidth=0.8,
    )
    ax.set_xlabel("用户评分（星）")
    ax.set_ylabel("评论数")
    ax.set_title("用户评分与 LLM 情感判断交叉分布", fontsize=14, pad=12)
    ax.legend(["正面", "中性", "负面"], frameon=False)
    ax.grid(axis="y", alpha=0.25)
    ax.set_axisbelow(True)
    plt.xticks(rotation=0)
    plt.tight_layout()
    path = os.path.join(OUT, "rating_vs_sentiment.png")
    fig.savefig(path, dpi=160, bbox_inches="tight")
    plt.close(fig)


if __name__ == "__main__":
    chart_sentiment_by_app()
    chart_issue_distribution()
    chart_issue_heatmap()
    chart_rating_vs_sentiment()
    print("图表已生成：")
    for name in sorted(os.listdir(OUT)):
        if name.endswith(".png"):
            print(" -", os.path.join(OUT, name))
