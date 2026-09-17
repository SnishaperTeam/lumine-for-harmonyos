export function formatBytes(bytes: number): string {
  const value = typeof bytes === 'number' && Number.isFinite(bytes) && bytes > 0 ? bytes : 0;
  if (value < 1024) {
    return value + ' B';
  }
  if (value < 1024 * 1024) {
    return (value / 1024).toFixed(1) + ' KB';
  }
  if (value < 1024 * 1024 * 1024) {
    return (value / (1024 * 1024)).toFixed(2) + ' MB';
  }
  return (value / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

export function formatUptime(ms: number): string {
  if (typeof ms !== 'number' || !Number.isFinite(ms) || ms <= 0) {
    return '00:00:00';
  }
  const totalSeconds = Math.floor(ms / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  return `${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
}

export function formatRelativeTime(timestamp: number): string {
  if (typeof timestamp !== 'number' || !Number.isFinite(timestamp) || timestamp <= 0) {
    return '时间未知';
  }
  const now = Date.now();
  const diff = now - timestamp;
  if (diff < 60000) {
    return '刚刚';
  }
  if (diff < 3600000) {
    return Math.floor(diff / 60000) + '分钟前';
  }
  if (diff < 86400000) {
    return Math.floor(diff / 3600000) + '小时前';
  }
  return Math.floor(diff / 86400000) + '天前';
}

export function generateConfigName(subscriptionName: string): string {
  const now = new Date();
  const timestamp = `${now.getFullYear()}${(now.getMonth() + 1).toString().padStart(2, '0')}${now.getDate().toString().padStart(2, '0')}`;
  const sanitized = subscriptionName.replace(/[^a-zA-Z0-9\u4e00-\u9fff]/g, '_').substring(0, 20);
  return `${sanitized}_${timestamp}`;
}
