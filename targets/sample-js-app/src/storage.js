const KEY = "sample-js-app:items";

export function readCache() {
  try {
    return JSON.parse(localStorage.getItem(KEY) ?? "[]");
  } catch {
    return [];
  }
}

export function writeCache(items) {
  localStorage.setItem(KEY, JSON.stringify(items));
}
