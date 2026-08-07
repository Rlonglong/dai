#!/bin/bash
# 使用方式: ./push_and_scan.sh gitlab-runner v3.1

IMAGE_NAME=$1
IMAGE_TAG=$2
GITLAB_PROJECT_ID="1"  # 在專案首頁看得到
TRIGGER_TOKEN="glptt-4Quh8muYiH2-sK94uuHs"

echo "正在推播映像檔..."
docker push gitlab.dai.post.gov.tw:5050/system-managers/infra/${IMAGE_NAME}:${IMAGE_TAG}

if [ $? -eq 0 ]; then
  echo "推播成功！正在觸發 CI 進行掃描與 Retag..."
  curl -X POST \
       -F token=${TRIGGER_TOKEN} \
       -F ref=main \
       -F "variables[IMAGE_NAME]=${IMAGE_NAME}" \
       -F "variables[IMAGE_TAG]=${IMAGE_TAG}" \
       https://gitlab.dai.post.gov.tw/api/v4/projects/${GITLAB_PROJECT_ID}/trigger/pipeline
  echo -e "\nCI 已觸發！"
else
  echo "推播失敗，終止流程。"
fi