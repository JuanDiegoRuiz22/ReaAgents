import { loadItems } from "./api.js";
import { readCache, writeCache } from "./storage.js";

function render(items) {
  const list = document.getElementById("items");
  list.replaceChildren(
    ...items.map((item) => {
      const li = document.createElement("li");
      li.textContent = `${item.name} (${item.qty})`;
      return li;
    }),
  );
}

async function refresh() {
  try {
    const items = await loadItems();
    writeCache(items);
    render(items);
  } catch {
    render(readCache());
  }
}

document.getElementById("reload").addEventListener("click", refresh);
render(readCache());
