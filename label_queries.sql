-- ============================================================
-- 打标结果分析查询
-- 依赖：review_labels 已有数据
-- 建议在 PyCharm Database 或 mysql 客户端中逐条运行
-- ============================================================

USE ai_reviews;
SET NAMES utf8mb4;

-- ------------------------------------------------------------
-- Q1 各产品情感分布
-- ------------------------------------------------------------
SELECT
  app_name,
  sentiment,
  review_count,
  pct
FROM ads_app_sentiment
ORDER BY app_name, FIELD(sentiment, 'positive', 'neutral', 'negative');

-- ------------------------------------------------------------
-- Q2 各产品 Top 3 问题（只看负面评论，排除“其他”）
-- ------------------------------------------------------------
WITH issue AS (
  SELECT
    app_name,
    issue_category,
    COUNT(*)                 AS review_count,
    ROUND(AVG(severity), 2)  AS avg_severity
  FROM v_labeled_reviews
  WHERE sentiment = 'negative'
    AND issue_category <> '其他'
  GROUP BY app_name, issue_category
),
ranked AS (
  SELECT
    *,
    RANK() OVER (
      PARTITION BY app_name ORDER BY review_count DESC
    ) AS rk
  FROM issue
)
SELECT
  app_name,
  rk,
  issue_category,
  review_count,
  avg_severity
FROM ranked
WHERE rk <= 3
ORDER BY app_name, rk;

-- ------------------------------------------------------------
-- Q3 整体问题 Top 榜 + 可行动比例
-- ------------------------------------------------------------
SELECT
  issue_category,
  COUNT(*)                                        AS review_count,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,
  ROUND(AVG(severity), 2)                         AS avg_severity,
  ROUND(100 * AVG(is_actionable), 2)              AS actionable_rate
FROM v_labeled_reviews
WHERE sentiment = 'negative'
  AND issue_category <> '其他'
GROUP BY issue_category
ORDER BY review_count DESC;

-- ------------------------------------------------------------
-- Q4 评分 vs 情感交叉表（检查模型是否和评分明显冲突）
-- ------------------------------------------------------------
SELECT
  rating,
  SUM(sentiment = 'positive') AS positive,
  SUM(sentiment = 'neutral')  AS neutral,
  SUM(sentiment = 'negative') AS negative,
  COUNT(*)                    AS total
FROM v_labeled_reviews
GROUP BY rating
ORDER BY rating;

-- ------------------------------------------------------------
-- Q5 严重且可行动的差评样本（做报告引用前先脱敏）
-- ------------------------------------------------------------
SELECT
  app_name,
  issue_category,
  severity,
  votes,
  LEFT(content, 100) AS content
FROM v_labeled_reviews
WHERE sentiment = 'negative'
  AND severity = 3
  AND is_actionable = 1
ORDER BY votes DESC, content_len DESC
LIMIT 20;

-- ------------------------------------------------------------
-- Q6 各产品打标总览
-- ------------------------------------------------------------
SELECT
  app_name,
  labeled_count,
  negative_rate,
  avg_severity,
  actionable_rate,
  avg_confidence
FROM ads_app_label_overview
ORDER BY negative_rate DESC;

-- ------------------------------------------------------------
-- Q7 模型判断和评分冲突的样本（人工复核用）
-- ------------------------------------------------------------
SELECT
  app_name,
  rating,
  sentiment,
  issue_category,
  confidence,
  LEFT(content, 80) AS content
FROM v_labeled_reviews
WHERE (rating >= 4 AND sentiment = 'negative')
   OR (rating <= 2 AND sentiment = 'positive')
ORDER BY confidence ASC
LIMIT 30;

-- ------------------------------------------------------------
-- Q8 低置信度样本（优先人工检查）
-- ------------------------------------------------------------
SELECT
  app_name,
  rating,
  sentiment,
  issue_category,
  confidence,
  LEFT(content, 80) AS content
FROM v_labeled_reviews
WHERE confidence < 0.7
ORDER BY confidence ASC
LIMIT 30;
