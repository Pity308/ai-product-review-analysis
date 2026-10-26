-- ============================================================
-- AI 产品评论 · 数据清洗脚本
-- 输入：reviews_raw（原始表，3497 条）
-- 输出：reviews_clean（规范表，供后续分析）
-- 清洗内容：
--   ① 过滤无意义短评（少于 5 个字，如"无""很好"）
--   ② 时间：字符串 → 标准 DATETIME，美西时间(-07:00) → 中国时间(+08:00)
--   ③ 去重（当前数据无重复，保留 DISTINCT 作为规范习惯）
-- 说明：可重复运行，每次会重建 reviews_clean
-- ============================================================

USE ai_reviews;
SET NAMES utf8mb4;

DROP TABLE IF EXISTS reviews_clean;

-- ① 建规范表结构（字段类型正确，带列注释）
CREATE TABLE reviews_clean (
  id          INT AUTO_INCREMENT PRIMARY KEY COMMENT '自增ID',
  app         VARCHAR(50)  COMMENT '产品名',
  rating      TINYINT      COMMENT '评分 1~5',
  version     VARCHAR(50)  COMMENT 'App 版本号',
  review_time DATETIME     COMMENT '评论时间（中国时区）',
  title       VARCHAR(255) COMMENT '评论标题',
  content     TEXT         COMMENT '评论正文',
  author      VARCHAR(255) COMMENT '用户名',
  votes       INT          COMMENT '点赞数'
) COMMENT 'AI产品评论：清洗表';

-- ② 清洗 + 插入
INSERT INTO reviews_clean (app, rating, version, review_time, title, content, author, votes)
SELECT DISTINCT
    app,
    rating,
    version,
    -- 字符串 → DATETIME，并从美西时间(-07:00)换算为中国时间(+08:00)
    CONVERT_TZ(
        STR_TO_DATE(LEFT(`time`, 19), '%Y-%m-%dT%H:%i:%s'),
        RIGHT(`time`, 6),
        '+08:00'
    ),
    title, content, author, votes
FROM reviews_raw
WHERE CHAR_LENGTH(TRIM(content)) >= 5;   -- 过滤少于5字的短评

-- ③ 验证
SELECT COUNT(*) AS `清洗后条数` FROM reviews_clean;

SELECT app AS `产品`, COUNT(*) AS `条数`, ROUND(AVG(rating), 2) AS `平均分`
FROM reviews_clean
GROUP BY app
ORDER BY `平均分` DESC;
