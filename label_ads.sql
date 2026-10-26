-- ============================================================
-- 打标后的分析视图
-- 依赖：review_labels + v_review_enriched + dim_app
-- 说明：用视图而不是表，重新打标后结果会自动更新
-- ============================================================

USE ai_reviews;
SET NAMES utf8mb4;

DROP VIEW IF EXISTS ads_app_sentiment;
DROP VIEW IF EXISTS ads_app_issue;
DROP VIEW IF EXISTS ads_app_label_overview;

-- 各产品情感分布
CREATE VIEW ads_app_sentiment AS
SELECT
  x.app_name,
  x.label_version,
  x.sentiment,
  x.review_count,
  ROUND(100 * x.review_count / t.total, 2) AS pct
FROM (
  SELECT
    a.app_name,
    l.label_version,
    l.sentiment,
    COUNT(*) AS review_count
  FROM review_labels l
  JOIN v_review_enriched r ON r.review_id = l.review_id
  JOIN dim_app a ON a.app_name = r.app_name
  GROUP BY a.app_name, l.label_version, l.sentiment
) x
JOIN (
  SELECT
    a.app_name,
    l.label_version,
    COUNT(*) AS total
  FROM review_labels l
  JOIN v_review_enriched r ON r.review_id = l.review_id
  JOIN dim_app a ON a.app_name = r.app_name
  GROUP BY a.app_name, l.label_version
) t
  ON t.app_name = x.app_name
 AND t.label_version = x.label_version;

-- 各产品问题类别分布
CREATE VIEW ads_app_issue AS
SELECT
  x.app_name,
  x.label_version,
  x.issue_category,
  x.review_count,
  ROUND(100 * x.review_count / t.total, 2) AS pct,
  x.avg_severity
FROM (
  SELECT
    a.app_name,
    l.label_version,
    l.issue_category,
    COUNT(*) AS review_count,
    ROUND(AVG(l.severity), 2) AS avg_severity
  FROM review_labels l
  JOIN v_review_enriched r ON r.review_id = l.review_id
  JOIN dim_app a ON a.app_name = r.app_name
  GROUP BY a.app_name, l.label_version, l.issue_category
) x
JOIN (
  SELECT
    a.app_name,
    l.label_version,
    COUNT(*) AS total
  FROM review_labels l
  JOIN v_review_enriched r ON r.review_id = l.review_id
  JOIN dim_app a ON a.app_name = r.app_name
  GROUP BY a.app_name, l.label_version
) t
  ON t.app_name = x.app_name
 AND t.label_version = x.label_version;

-- 各产品打标总览
CREATE VIEW ads_app_label_overview AS
SELECT
  a.app_name,
  l.label_version,
  COUNT(*)                                        AS labeled_count,
  ROUND(100 * AVG(l.sentiment = 'negative'), 2)   AS negative_rate,
  ROUND(AVG(l.severity), 2)                       AS avg_severity,
  ROUND(100 * AVG(l.is_actionable), 2)            AS actionable_rate,
  ROUND(AVG(l.confidence), 2)                     AS avg_confidence
FROM review_labels l
JOIN v_review_enriched r ON r.review_id = l.review_id
JOIN dim_app a ON a.app_name = r.app_name
GROUP BY a.app_name, l.label_version;
