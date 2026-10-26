-- ============================================================
-- AI 产品评论分析 · 星型模型 + 分层数仓
-- ------------------------------------------------------------
-- 分层设计：
--   ODS   reviews_raw          原始数据（已存在）
--   DWD   dwd_review_detail    清洗/时区/去重/质量标记，粒度 = 一条评论
--   DIM   dim_app / dim_date   产品维、日期维
--   FACT  fact_review          事实表，粒度 = 一条评论
--   DWS   dws_app_daily        轻度汇总，粒度 = App-天
--   ADS   ads_app_summary      应用层总览，供报表/简历使用
--         ads_app_rating_dist  评分分布
--   视图  v_review_enriched    事实 + 维度 + 评论文本，方便临时分析
--
-- 关键约定：
--   1. 保留全部评论，短评用 is_short_content 标记，不再直接删掉。
--      评分指标用全量，文本分析再过滤，避免短评过滤带来的偏差。
--   2. 脚本可重复运行：每次重建所有派生表，不改 reviews_raw / reviews_clean。
--   3. 不建外键（数仓常见做法），用索引保证关联性能。
-- ============================================================

USE ai_reviews;
SET NAMES utf8mb4;
SET SESSION cte_max_recursion_depth = 2000;

DROP VIEW  IF EXISTS v_review_enriched;
DROP TABLE IF EXISTS fact_review;
DROP TABLE IF EXISTS dws_app_daily;
DROP TABLE IF EXISTS ads_app_summary;
DROP TABLE IF EXISTS ads_app_rating_dist;
DROP TABLE IF EXISTS dwd_review_detail;
DROP TABLE IF EXISTS dim_app;
DROP TABLE IF EXISTS dim_date;

-- ============================================================
-- 1. 维度表：产品
-- ============================================================
CREATE TABLE dim_app (
  app_key      INT AUTO_INCREMENT PRIMARY KEY COMMENT '代理键',
  app_name     VARCHAR(50) NOT NULL COMMENT '产品名',
  app_store_id BIGINT COMMENT 'App Store ID',
  category     VARCHAR(50) NOT NULL DEFAULT 'AI助手' COMMENT '品类',
  UNIQUE KEY uk_app_name (app_name)
) COMMENT = '维度：产品';

INSERT INTO dim_app (app_name, app_store_id) VALUES
  ('豆包',     6459478672),
  ('DeepSeek', 6737597349),
  ('文心一言', 6446882473),
  ('Kimi',     6474233312),
  ('通义千问', 6466733523),
  ('腾讯元宝', 6480446430),
  ('智谱清言', 6450893458);

-- ============================================================
-- 2. 维度表：日期
--    用递归 CTE 生成数据覆盖的完整日期序列
-- ============================================================
CREATE TABLE dim_date (
  date_key      INT PRIMARY KEY COMMENT 'YYYYMMDD',
  full_date     DATE NOT NULL,
  year_num      SMALLINT,
  quarter_num   TINYINT,
  month_num     TINYINT,
  day_of_month  TINYINT,
  week_of_year  TINYINT COMMENT 'ISO 周，周一为一周第一天',
  weekday_num   TINYINT COMMENT '1=周日 ... 7=周六',
  weekday_name  VARCHAR(10),
  is_weekend    TINYINT(1) NOT NULL DEFAULT 0
) COMMENT = '维度：日期';

INSERT INTO dim_date (
  date_key, full_date, year_num, quarter_num, month_num,
  day_of_month, week_of_year, weekday_num, weekday_name, is_weekend
)
WITH RECURSIVE date_series AS (
  SELECT DATE(MIN(
           CONVERT_TZ(
             STR_TO_DATE(LEFT(`time`, 19), '%Y-%m-%dT%H:%i:%s'),
             RIGHT(`time`, 6),
             '+08:00'
           )
         )) AS d
  FROM reviews_raw
  UNION ALL
  SELECT DATE_ADD(d, INTERVAL 1 DAY)
  FROM date_series
  WHERE d < (
    SELECT DATE(MAX(
             CONVERT_TZ(
               STR_TO_DATE(LEFT(`time`, 19), '%Y-%m-%dT%H:%i:%s'),
               RIGHT(`time`, 6),
               '+08:00'
             )
           ))
    FROM reviews_raw
  )
)
SELECT
  CAST(DATE_FORMAT(d, '%Y%m%d') AS UNSIGNED) AS date_key,
  d,
  YEAR(d),
  QUARTER(d),
  MONTH(d),
  DAY(d),
  WEEK(d, 3),
  DAYOFWEEK(d),
  CASE DAYOFWEEK(d)
    WHEN 1 THEN '周日'
    WHEN 2 THEN '周一'
    WHEN 3 THEN '周二'
    WHEN 4 THEN '周三'
    WHEN 5 THEN '周四'
    WHEN 6 THEN '周五'
    ELSE '周六'
  END,
  IF(DAYOFWEEK(d) IN (1, 7), 1, 0)
FROM date_series;

-- ============================================================
-- 3. DWD：评论明细
--    - 字符串时间 -> DATETIME，美西时间 -> 中国时间
--    - 去重：同一产品 + 时间 + 内容 只保留一条
--    - 质量标记：content_len、is_short_content
--    - 保留全部 3497 条，短评不删除
-- ============================================================
CREATE TABLE dwd_review_detail (
  review_id        BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT '评论代理键',
  app_name         VARCHAR(50) NOT NULL COMMENT '产品名',
  rating           TINYINT NOT NULL COMMENT '评分 1~5',
  version          VARCHAR(50) COMMENT 'App 版本',
  review_time      DATETIME NOT NULL COMMENT '评论时间（中国时区）',
  title            VARCHAR(255) COMMENT '标题',
  content          TEXT NOT NULL COMMENT '正文（已 TRIM）',
  author           VARCHAR(255) COMMENT '用户名',
  votes            INT NOT NULL DEFAULT 0 COMMENT '点赞数',
  content_len      INT NOT NULL COMMENT '正文长度（字符）',
  is_short_content TINYINT(1) NOT NULL COMMENT '1=少于5字，文本分析时过滤',
  KEY idx_app_time (app_name, review_time),
  KEY idx_short (is_short_content)
) COMMENT = 'DWD：评论明细，粒度 = 一条评论';

INSERT INTO dwd_review_detail (
  app_name, rating, version, review_time, title,
  content, author, votes, content_len, is_short_content
)
SELECT
  app_name, rating, version, review_time, title, content, author, votes,
  CHAR_LENGTH(content) AS content_len,
  IF(CHAR_LENGTH(content) < 5, 1, 0) AS is_short_content
FROM (
  SELECT
    app_name, rating, version, review_time, title, content, author, votes,
    ROW_NUMBER() OVER (
      PARTITION BY app_name, review_time, SHA2(content, 256)
    ) AS rn
  FROM (
    SELECT
      app AS app_name,
      rating,
      version,
      CONVERT_TZ(
        STR_TO_DATE(LEFT(`time`, 19), '%Y-%m-%dT%H:%i:%s'),
        RIGHT(`time`, 6),
        '+08:00'
      ) AS review_time,
      title,
      TRIM(content) AS content,
      author,
      IFNULL(votes, 0) AS votes
    FROM reviews_raw
    WHERE rating BETWEEN 1 AND 5
      AND `time` IS NOT NULL
      AND content IS NOT NULL
      AND TRIM(content) <> ''
  ) base
) dedup
WHERE rn = 1;

-- ============================================================
-- 4. FACT：评论事实表
--    粒度 = 一条评论；度量 = rating / votes / content_len
-- ============================================================
CREATE TABLE fact_review (
  review_id        BIGINT PRIMARY KEY COMMENT '与 DWD 的 review_id 一致',
  app_key          INT NOT NULL COMMENT '产品维键',
  date_key         INT NOT NULL COMMENT '日期维键 YYYYMMDD',
  rating           TINYINT NOT NULL COMMENT '评分度量',
  votes            INT NOT NULL DEFAULT 0 COMMENT '点赞数度量',
  content_len      INT NOT NULL COMMENT '正文长度度量',
  is_short_content TINYINT(1) NOT NULL COMMENT '是否短评',
  KEY idx_app_date (app_key, date_key),
  KEY idx_date (date_key),
  KEY idx_rating (rating)
) COMMENT = '事实：评论，粒度 = 一条评论';

INSERT INTO fact_review (
  review_id, app_key, date_key, rating, votes, content_len, is_short_content
)
SELECT
  d.review_id,
  a.app_key,
  CAST(DATE_FORMAT(d.review_time, '%Y%m%d') AS UNSIGNED) AS date_key,
  d.rating,
  d.votes,
  d.content_len,
  d.is_short_content
FROM dwd_review_detail d
JOIN dim_app a ON a.app_name = d.app_name;

-- ============================================================
-- 5. DWS：App-天 汇总
-- ============================================================
CREATE TABLE dws_app_daily (
  app_key          INT NOT NULL,
  date_key         INT NOT NULL,
  review_count     INT NOT NULL,
  avg_rating       DECIMAL(4,2),
  positive_count   INT COMMENT 'rating >= 4',
  neutral_count    INT COMMENT 'rating = 3',
  negative_count   INT COMMENT 'rating <= 2',
  avg_content_len  DECIMAL(8,2),
  total_votes      INT,
  valid_text_count INT COMMENT '非短评数，供文本分析',
  PRIMARY KEY (app_key, date_key)
) COMMENT = 'DWS：App-天 汇总';

INSERT INTO dws_app_daily (
  app_key, date_key, review_count, avg_rating,
  positive_count, neutral_count, negative_count,
  avg_content_len, total_votes, valid_text_count
)
SELECT
  app_key,
  date_key,
  COUNT(*) AS review_count,
  ROUND(AVG(rating), 2) AS avg_rating,
  SUM(rating >= 4) AS positive_count,
  SUM(rating = 3) AS neutral_count,
  SUM(rating <= 2) AS negative_count,
  ROUND(AVG(content_len), 2) AS avg_content_len,
  SUM(votes) AS total_votes,
  SUM(is_short_content = 0) AS valid_text_count
FROM fact_review
GROUP BY app_key, date_key;

-- ============================================================
-- 6. ADS：应用层
-- ============================================================
CREATE TABLE ads_app_summary (
  app_key            INT PRIMARY KEY,
  total_reviews      INT NOT NULL,
  valid_text_reviews INT NOT NULL COMMENT '非短评数',
  avg_rating         DECIMAL(4,2),
  positive_rate      DECIMAL(5,2) COMMENT 'rating>=4 占比 %',
  neutral_rate       DECIMAL(5,2),
  negative_rate      DECIMAL(5,2) COMMENT 'rating<=2 占比 %',
  five_star_rate     DECIMAL(5,2),
  one_star_rate      DECIMAL(5,2),
  avg_content_len    DECIMAL(8,2),
  first_review_date  DATE,
  last_review_date   DATE
) COMMENT = 'ADS：产品总览';

INSERT INTO ads_app_summary (
  app_key, total_reviews, valid_text_reviews, avg_rating,
  positive_rate, neutral_rate, negative_rate,
  five_star_rate, one_star_rate, avg_content_len,
  first_review_date, last_review_date
)
SELECT
  f.app_key,
  COUNT(*) AS total_reviews,
  SUM(f.is_short_content = 0) AS valid_text_reviews,
  ROUND(AVG(f.rating), 2) AS avg_rating,
  ROUND(100 * SUM(f.rating >= 4) / COUNT(*), 2) AS positive_rate,
  ROUND(100 * SUM(f.rating = 3) / COUNT(*), 2) AS neutral_rate,
  ROUND(100 * SUM(f.rating <= 2) / COUNT(*), 2) AS negative_rate,
  ROUND(100 * SUM(f.rating = 5) / COUNT(*), 2) AS five_star_rate,
  ROUND(100 * SUM(f.rating = 1) / COUNT(*), 2) AS one_star_rate,
  ROUND(AVG(f.content_len), 2) AS avg_content_len,
  MIN(d.full_date) AS first_review_date,
  MAX(d.full_date) AS last_review_date
FROM fact_review f
JOIN dim_date d ON d.date_key = f.date_key
GROUP BY f.app_key;

CREATE TABLE ads_app_rating_dist (
  app_key      INT NOT NULL,
  rating       TINYINT NOT NULL,
  review_count INT NOT NULL,
  rate_pct     DECIMAL(5,2) COMMENT '该评分占比 %',
  PRIMARY KEY (app_key, rating)
) COMMENT = 'ADS：评分分布';

INSERT INTO ads_app_rating_dist (app_key, rating, review_count, rate_pct)
SELECT
  f.app_key,
  f.rating,
  COUNT(*) AS review_count,
  ROUND(100 * COUNT(*) / s.total_reviews, 2) AS rate_pct
FROM fact_review f
JOIN ads_app_summary s ON s.app_key = f.app_key
GROUP BY f.app_key, f.rating, s.total_reviews;

-- ============================================================
-- 7. 宽表视图：事实 + 维度 + 文本，方便直接查询
-- ============================================================
CREATE OR REPLACE VIEW v_review_enriched AS
SELECT
  f.review_id,
  a.app_name,
  d.full_date,
  f.rating,
  f.votes,
  f.content_len,
  f.is_short_content,
  r.version,
  r.title,
  r.content
FROM fact_review f
JOIN dim_app a ON a.app_key = f.app_key
JOIN dim_date d ON d.date_key = f.date_key
JOIN dwd_review_detail r ON r.review_id = f.review_id;

-- ============================================================
-- 8. 验证
-- ============================================================
SELECT 'dim_app' AS table_name, COUNT(*) AS rows_count FROM dim_app
UNION ALL SELECT 'dim_date', COUNT(*) FROM dim_date
UNION ALL SELECT 'dwd_review_detail', COUNT(*) FROM dwd_review_detail
UNION ALL SELECT 'fact_review', COUNT(*) FROM fact_review
UNION ALL SELECT 'dws_app_daily', COUNT(*) FROM dws_app_daily
UNION ALL SELECT 'ads_app_summary', COUNT(*) FROM ads_app_summary
UNION ALL SELECT 'ads_app_rating_dist', COUNT(*) FROM ads_app_rating_dist;

SELECT
  a.app_name,
  s.total_reviews,
  s.valid_text_reviews,
  s.avg_rating,
  s.negative_rate,
  s.first_review_date,
  s.last_review_date
FROM ads_app_summary s
JOIN dim_app a ON a.app_key = s.app_key
ORDER BY s.total_reviews DESC;
