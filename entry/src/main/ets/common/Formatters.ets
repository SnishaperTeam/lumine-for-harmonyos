export function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return bytes + ' B';
  }
  if (bytes < 1024 * 1024) {
    return (bytes / 1024).toFixed(1) + ' KB';
  }
  return (bytes / (1024 * 1024)).toFixed(2) + ' MB';
}

export function formatUptime(ms: number): string {
  if (ms <= 0) {
    return '00:00:00';
  }
  const totalSeconds = Math.floor(ms / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  return `${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
}

export function formatRelativeTime(timestamp: number): string {
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
