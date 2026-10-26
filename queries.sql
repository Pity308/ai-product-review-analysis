-- ============================================================
-- AI 产品评论分析 · 示例查询
-- 对应数仓分层：fact_review / dws_app_daily / ads_* / v_review_enriched
-- 直接运行：mysql -uroot --default-character-set=utf8mb4 < queries.sql
-- ============================================================

USE ai_reviews;
SET NAMES utf8mb4;

-- ------------------------------------------------------------
-- Q1 全量 vs 文本样本：验证短评过滤的偏差
-- 结论：评分指标看 all_reviews，文本分析才用 valid_text
-- ------------------------------------------------------------
SELECT
  COUNT(*)                                              AS all_reviews,
  SUM(is_short_content = 0)                             AS valid_text_reviews,
  ROUND(AVG(rating), 2)                                 AS avg_rating_all,
  ROUND(AVG(CASE WHEN is_short_content = 0 THEN rating END), 2) AS avg_rating_text,
  ROUND(AVG(CASE WHEN is_short_content = 1 THEN rating END), 2) AS avg_rating_short
FROM fact_review;

-- ------------------------------------------------------------
-- Q2 产品总览 + 排名（窗口函数 RANK）
-- ------------------------------------------------------------
SELECT
  a.app_name,
  s.total_reviews,
  s.valid_text_reviews,
  s.avg_rating,
  s.negative_rate,
  s.five_star_rate,
  s.one_star_rate,
  RANK() OVER (ORDER BY s.avg_rating DESC) AS rating_rank,
  s.first_review_date,
  s.last_review_date
FROM ads_app_summary s
JOIN dim_app a ON a.app_key = s.app_key
ORDER BY s.avg_rating DESC;

-- ------------------------------------------------------------
-- Q3 评分分布（条件聚合，一行一个产品）
-- ------------------------------------------------------------
SELECT
  a.app_name,
  SUM(f.rating = 1) AS star_1,
  SUM(f.rating = 2) AS star_2,
  SUM(f.rating = 3) AS star_3,
  SUM(f.rating = 4) AS star_4,
  SUM(f.rating = 5) AS star_5,
  COUNT(*)          AS total
FROM fact_review f
JOIN dim_app a ON a.app_key = f.app_key
GROUP BY a.app_name
ORDER BY a.app_name;

-- ------------------------------------------------------------
-- Q4 共同时间窗对比
-- 2026-09-26 ~ 2026-10-11 是 DeepSeek 数据起点到各产品最新日期；
-- 注意：文心/智谱在该窗口样本很少，不能和其他产品直接比。
-- ------------------------------------------------------------
SET @window_start = '2026-09-26';
SET @window_end   = '2026-10-11';

SELECT
  a.app_name,
  COUNT(*)                                    AS review_count,
  ROUND(AVG(f.rating), 2)                     AS avg_rating,
  ROUND(100 * SUM(f.rating <= 2) / COUNT(*), 2) AS negative_rate,
  MIN(d.full_date)                            AS first_date,
  MAX(d.full_date)                            AS last_date
FROM fact_review f
JOIN dim_app a  ON a.app_key = f.app_key
JOIN dim_date d ON d.date_key = f.date_key
WHERE d.full_date BETWEEN @window_start AND @window_end
GROUP BY a.app_name
ORDER BY review_count DESC;

-- ------------------------------------------------------------
-- Q5 单产品日趋势 + 7 日移动平均（窗口函数）
-- 说明：这里对日均分做简单移动平均，样本少的日期波动会很大
-- ------------------------------------------------------------
SET @app_name = 'DeepSeek';

WITH daily AS (
  SELECT
    d.full_date,
    w.review_count,
    w.avg_rating
  FROM dws_app_daily w
  JOIN dim_app a  ON a.app_key = w.app_key
  JOIN dim_date d ON d.date_key = w.date_key
  WHERE a.app_name = @app_name
)
SELECT
  full_date,
  review_count,
  avg_rating,
  ROUND(
    AVG(avg_rating) OVER (
      ORDER BY full_date
      ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ), 2
  ) AS ma_7d
FROM daily
ORDER BY full_date;

-- ------------------------------------------------------------
-- Q6 月度趋势 + 环比（CTE + LAG）
-- ------------------------------------------------------------
WITH monthly AS (
  SELECT
    a.app_name,
    d.year_num,
    d.month_num,
    COUNT(*)                AS review_count,
    ROUND(AVG(f.rating), 2) AS avg_rating
  FROM fact_review f
  JOIN dim_app a  ON a.app_key = f.app_key
  JOIN dim_date d ON d.date_key = f.date_key
  GROUP BY a.app_name, d.year_num, d.month_num
)
SELECT
  app_name,
  year_num,
  month_num,
  review_count,
  avg_rating,
  LAG(avg_rating) OVER (
    PARTITION BY app_name ORDER BY year_num, month_num
  ) AS prev_avg_rating,
  ROUND(
    avg_rating - LAG(avg_rating) OVER (
      PARTITION BY app_name ORDER BY year_num, month_num
    ), 2
  ) AS diff
FROM monthly
WHERE app_name = 'Kimi'
ORDER BY year_num, month_num;

-- ------------------------------------------------------------
-- Q7 高赞差评（文本分析素材）
-- ------------------------------------------------------------
SELECT
  app_name,
  full_date,
  rating,
  votes,
  LEFT(content, 80) AS excerpt
FROM v_review_enriched
WHERE rating <= 2
  AND is_short_content = 0
ORDER BY votes DESC
LIMIT 20;

-- ------------------------------------------------------------
-- Q8 关键词命中率：LLM 分类前的快速摸底
-- ------------------------------------------------------------
SELECT
  app_name,
  COUNT(*) AS text_reviews,
  ROUND(100 * SUM(content LIKE '%闪退%') / COUNT(*), 2)                    AS crash_pct,
  ROUND(100 * SUM(content LIKE '%卡顿%') / COUNT(*), 2)                    AS lag_pct,
  ROUND(100 * SUM(content LIKE '%广告%') / COUNT(*), 2)                    AS ad_pct,
  ROUND(100 * SUM(content LIKE '%会员%' OR content LIKE '%收费%') / COUNT(*), 2) AS paywall_pct,
  ROUND(100 * SUM(content LIKE '%准确%' OR content LIKE '%错误%') / COUNT(*), 2) AS accuracy_pct,
  ROUND(100 * SUM(content LIKE '%登录%' OR content LIKE '%账号%') / COUNT(*), 2) AS account_pct
FROM v_review_enriched
WHERE is_short_content = 0
GROUP BY app_name
ORDER BY text_reviews DESC;

-- ------------------------------------------------------------
-- Q9 评分与正文长度/点赞的关系
-- ------------------------------------------------------------
SELECT
  rating,
  COUNT(*)                 AS review_count,
  ROUND(AVG(content_len), 1) AS avg_content_len,
  ROUND(AVG(votes), 1)       AS avg_votes
FROM fact_review
GROUP BY rating
ORDER BY rating;
