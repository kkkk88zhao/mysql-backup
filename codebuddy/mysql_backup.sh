#!/bin/bash
#
# MySQL 本地备份脚本
# 用法: ./mysql_backup.sh [数据库名]
#   不传参数则备份所有数据库
#

# ===== 配置 =====
MYSQL_USER="root"
MYSQL_PASS="root"
MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3306"
BACKUP_DIR="/root/mysql_backups"
KEEP_DAYS=7

# ===== 以下一般无需修改 =====
DATE=$(date +%Y%m%d_%H%M%S)
TIMESTAMP=$(date +%Y%m%d)
LOG_FILE="${BACKUP_DIR}/backup_${DATE}.log"

mkdir -p "${BACKUP_DIR}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

# 检查 mysqldump 是否可用
if ! command -v mysqldump &> /dev/null; then
    log "错误: 未找到 mysqldump 命令，请确认 MySQL 客户端已安装"
    exit 1
fi

# 测试数据库连接
if ! mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -e "SELECT 1" &> /dev/null; then
    log "错误: 无法连接到 MySQL，请检查用户名/密码/主机配置"
    exit 1
fi

# 获取要备份的数据库列表
if [ -n "$1" ]; then
    DATABASES=("$1")
else
    DATABASES=($(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" \
        -e "SHOW DATABASES" -s --skip-column-names 2>/dev/null | grep -v -E "^(information_schema|performance_schema|sys)$"))
fi

log "开始备份，共 ${#DATABASES[@]} 个数据库"

FAIL_COUNT=0
for DB in "${DATABASES[@]}"; do
    BACKUP_FILE="${BACKUP_DIR}/${DB}_${DATE}.sql.gz"

    log "正在备份数据库: ${DB}"

    if mysqldump -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" \
        --single-transaction --routines --triggers --events \
        "${DB}" 2>/dev/null | gzip > "${BACKUP_FILE}"; then

        SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
        log "备份成功: ${DB} -> ${BACKUP_FILE} (${SIZE})"
    else
        log "备份失败: ${DB}"
        rm -f "${BACKUP_FILE}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

# 清理过期备份
DELETED=$(find "${BACKUP_DIR}" -name "*.sql.gz" -type f -mtime +${KEEP_DAYS} -delete -print | wc -l)
log "已清理 ${DELETED} 个超过 ${KEEP_DAYS} 天的旧备份"

log "备份完成，成功 $(( ${#DATABASES[@]} - FAIL_COUNT ))/${#DATABASES[@]}，失败 ${FAIL_COUNT}"

exit ${FAIL_COUNT}
