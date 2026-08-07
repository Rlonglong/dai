#!/usr/bin/env python3
"""
DAI 磁碟用量告警：使用率超過門檻時透過 SMTP 寄信通知
部署路徑：/usr/local/bin/dai_disk_alert.py
"""
import shutil
import smtplib
import ssl
import socket
from email.message import EmailMessage
from pathlib import Path
from datetime import date

THRESHOLD = 90
ALERT_TO = ["ops-team@your-domain.tw"]
ALERT_FROM = "bigdata007@mail.post.gov.tw"
STATE_FILE = Path("/var/tmp/dai-disk-alert.state")

SMTP_HOST = "m2k.post.gov.tw"
SMTP_PORT = 110  # 若公司要求 SSL 而非 STARTTLS，改用 465 + SMTP_SSL
SMTP_USER = "bigdata007@mail.post.gov.tw"
SMTP_PASSWORD_FILE = Path("/etc/dai/smtp_secret")  # 權限務必設 600 root:root

# 依實際 bind mount 掛載點調整
CHECK_PATHS = {
    "/data": "/data (dai system useage)",
    "/var/log/dai": "/var (dai component logs)",
    "/var/log/dai-integrity": "/var (dai-integrity logs)"
}


def get_usage_percent(path: str) -> int:
    total, used, free = shutil.disk_usage(path)
    return int(used / total * 100)


def load_password() -> str:
    return SMTP_PASSWORD_FILE.read_text().strip()


def send_alert(body: str) -> None:
    msg = EmailMessage()
    msg["Subject"] = f"[DAI][{socket.gethostname()}] 磁碟空間告警"
    msg["From"] = ALERT_FROM
    msg["To"] = ", ".join(ALERT_TO)
    msg.set_content(body)

    context = ssl.create_default_context()
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=10) as server:
        server.starttls(context=context)
        server.login(SMTP_USER, load_password())
        server.send_message(msg)


def main() -> None:
    alerts = []
    for path, label in CHECK_PATHS.items():
        usage = get_usage_percent(path)
        if usage >= THRESHOLD:
            alerts.append(f"[警示] {label} 使用率 {usage}%（門檻 {THRESHOLD}%）")

    today = date.today().isoformat()

    if alerts:
        # 一天只發一次，避免洗版
        if STATE_FILE.exists() and STATE_FILE.read_text().strip() == today:
            return
        send_alert("\n".join(alerts))
        STATE_FILE.write_text(today)
    else:
        STATE_FILE.unlink(missing_ok=True)


if __name__ == "__main__":
    main()