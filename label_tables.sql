-- ============================================================
-- LLM 打标结果表
-- 粒度：一条评论 × 一个标签版本
-- 用途：同一批评论可以用不同模型/prompt 重复打标，便于对比效果
-- ============================================================

USE ai_reviews;
SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS review_labels (
  review_id     BIGINT NOT NULL COMMENT '对应 dwd_review_detail.review_id',
  label_version VARCHAR(50) NOT NULL COMMENT '标签版本，如 deepseek-chat-v1',
  model_name    VARCHAR(50) NOT NULL COMMENT '模型名',
  sentiment     ENUM('positive', 'neutral', 'negative') NOT NULL COMMENT '情感',
  issue_category VARCHAR(20) NOT NULL COMMENT '主要问题类别',
  severity      TINYINT NOT NULL COMMENT '1=轻微 2=影响使用 3=严重',
  is_actionable TINYINT(1) NOT NULL COMMENT '是否包含具体可改进信息',
  confidence    DECIMAL(3,2) COMMENT '置信度 0~1',
  key_quote     VARCHAR(100) COMMENT '原文关键句',
  raw_response  JSON COMMENT '模型原始返回，便于排查',
  created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (review_id, label_version),
  KEY idx_version_sentiment (label_version, sentiment),
  KEY idx_version_issue (label_version, issue_category)
) COMMENT = 'LLM 打标结果，粒度 = 评论 × 标签版本';

-- 打标后的宽表视图：分析时直接查这个
CREATE OR REPLACE VIEW v_labeled_reviews AS
SELECT
  r.review_id,
  r.app_name,
  r.full_date,
  r.rating,
  r.votes,
  r.content_len,
  r.is_short_content,
  r.version,
  r.title,
  r.content,
  l.label_version,
  l.model_name,
  l.sentiment,
  l.issue_category,
  l.severity,
  l.is_actionable,
  l.confidence,
  l.key_quote
FROM v_review_enriched r
JOIN review_labels l ON l.review_id = r.review_id;

SELECT COUNT(*) AS existing_labels FROM review_labels;
