#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# release.sh — 一键发布：更新版本 → 复制镜像 → 构建 LPK → 发布商店 → Git 提交
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ---- 默认值 ----
MANIFEST_FILE="lzc-manifest.yml"
PACKAGE_FILE="package.yml"
BUILD_FILE="lzc-build.yml"
CONFIG_FILE=".lazycat-release.env"

VERSION=""
SERVICE=""
SOURCE_IMAGE=""
SOURCE_TEMPLATE=""
CHANGELOG=""
COMMIT_MSG=""
LANG="zh"
DO_PUBLISH=1
DO_COMMIT=1
DO_PUSH=1
DRY_RUN=0

# ---- helpers ----
die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }
warn() { echo "⚠️  $*" >&2; }

usage() {
  cat <<'EOF'
Usage: ./release.sh <version> [options]

一键更新版本、发布到应用商店、提交到 Git 仓库。

Options:
  --changelog <text>           更新日志（默认: 更新到 <version>）
  --commit-message <msg>       自定义 commit 消息
  --source-image <image>       上游镜像地址
  --source-template <template> 上游镜像模板（如 forgejoclone/forgejo:{version}）
  --service <name>             要更新的服务名（默认自动检测）
  --no-publish                 只构建 LPK，不发布到应用商店
  --no-commit                  不执行 git commit
  --no-push                    不执行 git push
  --dry-run                    预览模式，不实际执行
  -h, --help                   显示帮助
EOF
}

# ---- 参数解析 ----
VERSION="${1:-}"
[[ -z "$VERSION" || "$VERSION" == "-h" || "$VERSION" == "--help" ]] && { usage; [[ "$VERSION" == "-h" || "$VERSION" == "--help" ]] && exit 0; exit 1; }
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --changelog)       CHANGELOG="${2:-}"; shift 2 ;;
    --commit-message)  COMMIT_MSG="${2:-}"; shift 2 ;;
    --source-image)    SOURCE_IMAGE="${2:-}"; shift 2 ;;
    --source-template) SOURCE_TEMPLATE="${2:-}"; shift 2 ;;
    --service)         SERVICE="${2:-}"; shift 2 ;;
    --no-publish)      DO_PUBLISH=0; shift ;;
    --no-commit)       DO_COMMIT=0; shift ;;
    --no-push)         DO_PUSH=0; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# ---- 从 manifest 注释中推导上游镜像 ----
find_service_from_manifest() {
  # 找到第一个 service 名
  awk '/^services:/ { found=1; next }
       found && /^  [A-Za-z0-9_.-]+:/ {
         svc=$1; sub(/:$/, "", svc); print svc; exit
       }' "$MANIFEST_FILE"
}

find_comment_upstream() {
  local svc="$1"
  # 查找 service 下 image: 行上方的注释（格式: # org/repo:tag）
  awk -v svc="$svc" '
    /^services:/ { in_svc=1; cur=""; comment=""; next }
    in_svc && /^  [A-Za-z0-9_.-]+:/ {
      cur=$1; sub(/:$/, "", cur); comment=""; next
    }
    in_svc && cur == svc && /^    # / {
      comment=$0; sub(/^[[:space:]]*#[[:space:]]*/, "", comment);
      gsub(/[[:space:]]*$/, "", comment); next
    }
    in_svc && cur == svc && /^    image:/ {
      if (comment ~ /^[a-zA-Z0-9].*:[a-zA-Z0-9]/) print comment
      exit
    }
' "$MANIFEST_FILE"
}

find_current_image() {
  local svc="$1"
  awk -v svc="$svc" '
    /^services:/ { in_svc=1; cur=""; next }
    in_svc && /^  [A-Za-z0-9_.-]+:/ {
      cur=$1; sub(/:$/, "", cur); next
    }
    in_svc && cur == svc && /^    image:/ {
      img=$0; sub(/^[[:space:]]*image:[[:space:]]*/, "", img);
      gsub(/^["\047]|["\047]$/, "", img); print img; exit
    }
' "$MANIFEST_FILE"
}

get_package_id() {
  awk -F':[[:space:]]*' '/^package:[[:space:]]*/ {
    v=$2; gsub(/["\047 ]/, "", v); print v; exit
  }' "$PACKAGE_FILE"
}

# ---- 推导 SERVICE 和 SOURCE_IMAGE ----
[[ -f "$MANIFEST_FILE" ]] || die "找不到 $MANIFEST_FILE"
[[ -f "$PACKAGE_FILE" ]] || die "找不到 $PACKAGE_FILE"
[[ -f "$BUILD_FILE" ]]   || die "找不到 $BUILD_FILE"

SERVICE="${SERVICE:-$(find_service_from_manifest)}"
[[ -n "$SERVICE" ]] || die "无法从 manifest 中检测到 service"

CURRENT_IMAGE=$(find_current_image "$SERVICE")
note "当前 service: $SERVICE"
note "当前镜像:    $CURRENT_IMAGE"

# 推导上游镜像
if [[ -z "$SOURCE_IMAGE" ]]; then
  if [[ -n "$SOURCE_TEMPLATE" ]]; then
    SOURCE_IMAGE="${SOURCE_TEMPLATE//\{version\}/$VERSION}"
  else
    COMMENT_UPSTREAM=$(find_comment_upstream "$SERVICE")
    if [[ -n "$COMMENT_UPSTREAM" ]]; then
      note "从注释推导上游镜像: $COMMENT_UPSTREAM"
      SOURCE_IMAGE="${COMMENT_UPSTREAM%:*}:${VERSION}"
    else
      die "无法推导上游镜像，请使用 --source-image 或 --source-template 指定"
    fi
  fi
fi

CHANGELOG="${CHANGELOG:-更新到 ${VERSION}}"
COMMIT_MSG="${COMMIT_MSG:-bump version to ${VERSION}}"
PACKAGE_ID=$(get_package_id)
LPK_FILE="${PACKAGE_ID}-v${VERSION}.lpk"

# ---- 打印计划 ----
BRANCH=$(git branch --show-current)
REPO_NAME=$(git remote get-url origin 2>/dev/null | sed 's|.*[:/]\([^/]*/[^/]*\)\.git$|\1|' || echo "unknown")

note "============================================"
note "  发布计划"
note "============================================"
note "  版本:          ${VERSION}"
note "  Service:       ${SERVICE}"
note "  上游镜像:      ${SOURCE_IMAGE}"
note "  更新日志:      ${CHANGELOG}"
note "  Commit 消息:   ${COMMIT_MSG}"
note "  仓库:          ${REPO_NAME}:${BRANCH}"
note "  发布到商店:    $([[ "$DO_PUBLISH" == "1" ]] && echo '✅' || echo '❌')"
note "  Git commit:    $([[ "$DO_COMMIT" == "1" ]] && echo '✅' || echo '❌')"
note "  Git push:      $([[ "$DO_PUSH" == "1" ]] && echo '✅' || echo '❌')"
[[ "$DRY_RUN" == "1" ]] && note "  模式:          🔍 DRY RUN"
note "============================================"

[[ "$DRY_RUN" == "1" ]] && exit 0

# ---- 检查工作区 ----
if [[ "$DO_COMMIT" == "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
  warn "工作区有未提交的更改，请先提交或暂存"
fi

# ============================
# Step 1: 复制镜像
# ============================
note ""
note "📦 Step 1/5: 复制镜像到 LazyCat Registry..."

# 优先使用 fish 函数，否则用 lzc-cli
if command -v fish >/dev/null 2>&1 && fish -lc 'functions -q lzc-copy-image' 2>/dev/null; then
  COPY_OUTPUT=$(COPY_IMAGE="$SOURCE_IMAGE" fish -lc 'lzc-copy-image "$COPY_IMAGE"' 2>&1) || {
    echo "$COPY_OUTPUT" >&2
    die "镜像复制失败"
  }
else
  COPY_OUTPUT=$(lzc-cli appstore copy-image "$SOURCE_IMAGE" 2>&1) || {
    echo "$COPY_OUTPUT" >&2
    die "镜像复制失败"
  }
fi

LAZYCAT_IMAGE=$(echo "$COPY_OUTPUT" | grep -Eo 'registry\.lazycat\.cloud/[A-Za-z0-9._:@/-]+' | tail -n 1)
[[ -n "$LAZYCAT_IMAGE" ]] || die "无法从输出中解析 LazyCat Registry 镜像地址"
note "  → $LAZYCAT_IMAGE"

# ============================
# Step 2: 更新配置文件
# ============================
note ""
note "📝 Step 2/5: 更新配置文件..."

# 更新 package.yml 版本
sed -i "s/^version:.*/version: ${VERSION}/" "$PACKAGE_FILE"
note "  package.yml → version: ${VERSION}"

# 更新 lzc-manifest.yml 镜像
awk -v svc="$SERVICE" -v img="$LAZYCAT_IMAGE" '
  BEGIN { in_svc=0; cur="" }
  /^services:/ { in_svc=1; print; next }
  in_svc && /^  [A-Za-z0-9_.-]+:/ {
    cur=$1; sub(/:$/, "", cur); print; next
  }
  in_svc && cur == svc && /^    image:/ {
    print "    image: " img; next
  }
  { print }
' "$MANIFEST_FILE" > "$MANIFEST_FILE.tmp" && mv "$MANIFEST_FILE.tmp" "$MANIFEST_FILE"
note "  lzc-manifest.yml → image: ${LAZYCAT_IMAGE}"

# 更新注释中的上游镜像版本
ESC_SRC=$(echo "$SOURCE_IMAGE" | sed 's/[\/&]/\\&/g')
sed -i "s/^    # .*:.*/    # ${ESC_SRC}/" "$MANIFEST_FILE"
note "  lzc-manifest.yml → 注释更新为: # ${SOURCE_IMAGE}"

# ============================
# Step 3: 构建 LPK
# ============================
note ""
note "🔨 Step 3/5: 构建 LPK..."

lzc-cli project build -f "$BUILD_FILE" || die "构建 LPK 失败"
[[ -f "$LPK_FILE" ]] || die "构建产物未找到: $LPK_FILE"
note "  → ${LPK_FILE}"

# ============================
# Step 4: 发布到应用商店
# ============================
if [[ "$DO_PUBLISH" == "1" ]]; then
  note ""
  note "🚀 Step 4/5: 发布到应用商店..."

  if command -v fish >/dev/null 2>&1 && fish -lc 'functions -q lzc-publish' 2>/dev/null; then
    LPK_FILE="$LPK_FILE" CHANGELOG="$CHANGELOG" LANG_CODE="$LANG" \
      fish -lc 'lzc-publish "$LPK_FILE" "$CHANGELOG" "$LANG_CODE"' || die "发布失败"
  else
    lzc-cli appstore publish "$LPK_FILE" -c "$CHANGELOG" --clang "$LANG" || die "发布失败"
  fi
  note "  ✅ 发布成功"
else
  note ""
  note "⏭️  Step 4/5: 跳过发布（--no-publish）"
fi

# ============================
# Step 5: Git commit & push
# ============================
if [[ "$DO_COMMIT" == "1" ]]; then
  note ""
  note "📝 Step 5/5: Git 提交..."

  git add "$PACKAGE_FILE" "$MANIFEST_FILE" "$CONFIG_FILE" 2>/dev/null || true
  git add cloud.lazycat.app.*-v"${VERSION}".lpk 2>/dev/null || true

  if git diff --cached --quiet; then
    warn "没有文件变更，跳过 commit"
  else
    note "  变更文件:"
    git diff --cached --name-only | while read -r f; do note "    $f"; done

    git commit -m "$COMMIT_MSG" \
               -m "更新到版本 ${VERSION}" \
               -m "🤖 Generated with [Claude Code](https://claude.com/claude-code)" \
      || die "git commit 失败"
    note "  ✅ commit 成功"

    if [[ "$DO_PUSH" == "1" ]]; then
      AHEAD=$(git rev-list --count "origin/${BRANCH}..${BRANCH}" 2>/dev/null || echo "0")
      if [[ "$AHEAD" == "0" ]]; then
        warn "没有需要推送的提交"
      else
        git push origin "$BRANCH" || die "git push 失败"
        note "  ✅ push 成功 (${AHEAD} commits)"
      fi
    else
      note "  ⏭️  跳过 push（--no-push）"
    fi
  fi
else
  note ""
  note "⏭️  Step 5/5: 跳过 Git 操作（--no-commit）"
fi

# ---- 完成 ----
note ""
note "============================================"
note "  🎉 发布完成！"
note "============================================"
note "  版本:    ${VERSION}"
note "  镜像:    ${LAZYCAT_IMAGE}"
note "  LPK:     ${LPK_FILE}"
note "  发布:    $([[ "$DO_PUBLISH" == "1" ]] && echo '✅' || echo '⏭️')"
note "  Commit:  $([[ "$DO_COMMIT" == "1" ]] && echo '✅' || echo '⏭️')"
note "  Push:    $([[ "$DO_PUSH" == "1" ]] && echo '✅' || echo '⏭️')"
note "============================================"
