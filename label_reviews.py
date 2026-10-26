# -*- coding: utf-8 -*-
"""用 DeepSeek 给 AI 产品评论打标。

用法：
    # 先看前 2 条会发什么 prompt，不调用 API
    python label_reviews.py --dry-run --limit 2

    # 小批量测试
    python label_reviews.py --limit 30

    # 全量（已打过的会自动跳过，可断点续跑）
    python label_reviews.py --workers 6

    # 如果遇到代理 502，可绕过代理重跑剩余数据
    NO_PROXY=api.deepseek.com python label_reviews.py --workers 3

API Key 放在项目目录的 .env 文件：
    DEEPSEEK_API_KEY=sk-xxxxxxxx
"""
import argparse
import json
import os
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import pymysql
import requests

# Windows 终端默认可能是 GBK，统一用 UTF-8 输出
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

BASE = os.path.dirname(os.path.abspath(__file__))
ENV_FILE = os.path.join(BASE, ".env")
API_URL = "https://api.deepseek.com/chat/completions"
MODEL = "deepseek-chat"
PROMPT_VERSION = "v1"
LABEL_VERSION = f"{MODEL}-{PROMPT_VERSION}"

SENTIMENTS = {"positive", "neutral", "negative"}
ISSUES = [
    "回答质量", "功能体验", "性能稳定性", "收费会员",
    "广告营销", "账号隐私", "内容审查", "界面更新", "其他",
]

SYSTEM_PROMPT = (
    "你是 AI 产品评论分析助手。请对一条 App Store 评论做结构化标注，"
    "只输出 JSON，不要输出任何解释或 Markdown。"
)

USER_TEMPLATE = """产品：{app}
用户评分：{rating}/5
标题：{title}
正文：{content}

请标注以下字段：
1. sentiment：positive / neutral / negative，综合正文和评分判断。
2. issue_category：从下面选一个最贴切的类别：
   - 回答质量：答案错误、幻觉、逻辑差、不准确、答非所问、生成质量差
   - 功能体验：功能缺失、操作不便、功能不好用
   - 性能稳定性：闪退、卡顿、加载慢、崩溃、网络问题
   - 收费会员：价格、订阅、会员权益、额度、退款
   - 广告营销：广告多、推广、营销骚扰
   - 账号隐私：登录、注册、封号、数据隐私、自动登录
   - 内容审查：敏感词、限制发言、内容被屏蔽
   - 界面更新：UI、改版、更新后体验变化
   - 其他：无法归入以上类别
3. severity：1=轻微抱怨，2=影响使用，3=严重问题/要求退款/卸载。
4. is_actionable：true=包含具体可改进的问题或建议，false=纯情绪/无信息。
5. key_quote：不超过 30 字的原文关键句。
6. confidence：0 到 1 之间的置信度。

只输出 JSON，字段名固定：
{{"sentiment": "...", "issue_category": "...", "severity": 1, "is_actionable": true, "key_quote": "...", "confidence": 0.9}}"""

_thread_local = threading.local()


def load_env(path):
    """读取简单的 .env 文件，不覆盖已有环境变量。"""
    if not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            os.environ.setdefault(key, value)


def get_session():
    if not hasattr(_thread_local, "session"):
        _thread_local.session = requests.Session()
    return _thread_local.session


def db_connect():
    return pymysql.connect(
        host=os.getenv("MYSQL_HOST", "localhost"),
        port=int(os.getenv("MYSQL_PORT", "3306")),
        user=os.getenv("MYSQL_USER", "root"),
        password=os.getenv("MYSQL_PASSWORD", ""),
        database="ai_reviews",
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=False,
    )


def fetch_reviews(conn, limit):
    # 小批量测试时随机抽样，避免只测到同一个产品
    order_by = "RAND()" if limit else "r.review_id"
    sql = f"""
        SELECT r.review_id, r.app_name, r.rating, r.title, r.content
        FROM v_review_enriched r
        WHERE r.is_short_content = 0
          AND NOT EXISTS (
              SELECT 1
              FROM review_labels l
              WHERE l.review_id = r.review_id
                AND l.label_version = %s
          )
        ORDER BY {order_by}
    """
    params = [LABEL_VERSION]
    if limit:
        sql += " LIMIT %s"
        params.append(limit)
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def build_prompt(row):
    return USER_TEMPLATE.format(
        app=row["app_name"],
        rating=row["rating"],
        title=(row["title"] or "").strip(),
        content=(row["content"] or "").strip()[:1500],
    )


def parse_json(text):
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text, flags=re.S)
    return json.loads(text)


def normalize(obj):
    sentiment = str(obj.get("sentiment", "")).strip().lower()
    if sentiment not in SENTIMENTS:
        raise ValueError(f"bad sentiment: {sentiment!r}")

    issue = str(obj.get("issue_category", "")).strip()
    if issue not in ISSUES:
        # 容忍模型输出 "功能体验（闪退）" 这类带后缀的类别
        matched = next((x for x in ISSUES if x in issue), None)
        if not matched:
            raise ValueError(f"bad issue_category: {issue!r}")
        issue = matched

    severity = int(obj.get("severity", 1))
    if severity not in (1, 2, 3):
        raise ValueError(f"bad severity: {severity!r}")

    actionable = obj.get("is_actionable", False)
    if isinstance(actionable, str):
        actionable = actionable.strip().lower() in ("true", "1", "yes")
    actionable = 1 if actionable else 0

    try:
        confidence = float(obj.get("confidence", 0.5))
    except (TypeError, ValueError):
        confidence = 0.5
    confidence = max(0.0, min(1.0, confidence))

    return {
        "sentiment": sentiment,
        "issue_category": issue,
        "severity": severity,
        "is_actionable": actionable,
        "key_quote": str(obj.get("key_quote", ""))[:100],
        "confidence": round(confidence, 2),
    }


class AuthError(RuntimeError):
    pass


def label_one(row, api_key, max_retries):
    prompt = build_prompt(row)
    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0,
        "max_tokens": 300,
        "response_format": {"type": "json_object"},
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    last_error = None
    for attempt in range(max_retries):
        try:
            resp = get_session().post(
                API_URL, headers=headers, json=payload, timeout=90
            )
            if resp.status_code == 401:
                raise AuthError("DeepSeek API Key 无效（401）")
            if resp.status_code == 429 or resp.status_code >= 500:
                raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:200]}")
            resp.raise_for_status()
            data = resp.json()
            content = data["choices"][0]["message"]["content"]
            obj = normalize(parse_json(content))
            return obj, data.get("usage", {})
        except AuthError:
            raise
        except Exception as e:
            last_error = e
            if attempt < max_retries - 1:
                time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"review_id={row['review_id']} 失败: {last_error}")


def insert_label(conn, row, label, usage):
    sql = """
        INSERT IGNORE INTO review_labels (
            review_id, label_version, model_name, sentiment, issue_category,
            severity, is_actionable, confidence, key_quote, raw_response
        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
    """
    with conn.cursor() as cur:
        cur.execute(sql, (
            row["review_id"],
            LABEL_VERSION,
            MODEL,
            label["sentiment"],
            label["issue_category"],
            label["severity"],
            label["is_actionable"],
            label["confidence"],
            label["key_quote"],
            json.dumps({"label": label, "usage": usage}, ensure_ascii=False),
        ))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=0, help="只处理前 N 条，0=全部")
    parser.add_argument("--workers", type=int, default=6, help="并发数")
    parser.add_argument("--max-retries", type=int, default=3)
    parser.add_argument("--dry-run", action="store_true", help="只打印 prompt，不调 API")
    args = parser.parse_args()

    load_env(ENV_FILE)
    api_key = os.getenv("DEEPSEEK_API_KEY", "").strip()
    if not api_key and not args.dry_run:
        sys.exit(
            "未找到 DEEPSEEK_API_KEY。\n"
            "请在项目目录新建 .env 文件，内容：DEEPSEEK_API_KEY=sk-xxxx"
        )

    conn = db_connect()
    try:
        rows = fetch_reviews(conn, args.limit)
        print(f"标签版本: {LABEL_VERSION}；待处理: {len(rows)} 条")
        if not rows:
            print("没有待打标的数据。")
            return

        if args.dry_run:
            for row in rows[:2]:
                print("=" * 60)
                print(f"review_id={row['review_id']}  {row['app_name']}  {row['rating']}星")
                print(build_prompt(row))
            print("=" * 60)
            print("dry-run 完成，未调用 API。")
            return

        done = failed = 0
        prompt_tokens = completion_tokens = 0
        started = time.time()

        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            future_to_row = {
                pool.submit(label_one, row, api_key, args.max_retries): row
                for row in rows
            }
            for future in as_completed(future_to_row):
                row = future_to_row[future]
                try:
                    label, usage = future.result()
                except AuthError as e:
                    print(f"\n认证失败: {e}")
                    pool.shutdown(wait=False, cancel_futures=True)
                    conn.commit()
                    return
                except Exception as e:
                    failed += 1
                    print(f"[FAIL] {e}")
                    continue

                insert_label(conn, row, label, usage)
                done += 1
                prompt_tokens += int(usage.get("prompt_tokens", 0) or 0)
                completion_tokens += int(usage.get("completion_tokens", 0) or 0)

                if done % 20 == 0:
                    conn.commit()
                    elapsed = time.time() - started
                    print(
                        f"进度 {done}/{len(rows)}，失败 {failed}，"
                        f"已用 {elapsed:.0f}s，tokens {prompt_tokens + completion_tokens}"
                    )

        conn.commit()
        print(
            f"完成：成功 {done} 条，失败 {failed} 条；"
            f"token 合计 {prompt_tokens + completion_tokens} "
            f"(prompt {prompt_tokens} / completion {completion_tokens})"
        )
        if failed:
            sys.exit(1)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
