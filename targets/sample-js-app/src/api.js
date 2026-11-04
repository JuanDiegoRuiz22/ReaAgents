// The host uses the reserved .invalid TLD (RFC 2606): it never resolves.
// If REA tried to contact it, the monitor would see the DNS lookup.
const API_BASE = "https://api.example.invalid/v1";

export async function loadItems() {
  const response = await fetch(`${API_BASE}/items`, {
    headers: { Accept: "application/json" },
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

export async function saveItem(item) {
  const response = await fetch(`${API_BASE}/items`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(item),
  });
  return response.ok;
}
