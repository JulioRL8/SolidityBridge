const searchOpen = document.querySelector("#search-open");
const dialog = document.querySelector("#search-dialog");
const input = document.querySelector("#search-input");
const results = document.querySelector("#search-results");
const status = document.querySelector("#search-status");
const pages = globalThis.solidityBridgePages;
let selected = -1;

function findPages(query) {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    if (!words.length) return pages.slice(0, 6);
    return pages
        .map((page) => {
            const title = page.title.toLowerCase();
            const summary = page.description.toLowerCase();
            const body = page.text.toLowerCase();
            const scores = words.map((term) => {
                if (title.includes(term)) return 8;
                if (summary.includes(term)) return 4;
                return body.includes(term) ? 1 : 0;
            });
            return { page, score: scores.every(Boolean) ? scores.reduce((a, b) => a + b, 0) : 0 };
        })
        .filter(({ score }) => score > 0)
        .sort((first, second) => second.score - first.score)
        .slice(0, 8)
        .map(({ page }) => page);
}

function selectResult(index, scroll = true) {
    const links = Array.from(results.querySelectorAll("a"));
    selected = links.length ? (index + links.length) % links.length : -1;
    links.forEach((link, position) => link.classList.toggle("is-selected", position === selected));
    if (scroll && selected >= 0) links[selected].scrollIntoView({ block: "nearest" });
}

function renderResults() {
    const matches = findPages(input.value);
    results.replaceChildren();
    status.textContent = input.value.trim()
        ? (matches.length ? `${matches.length} matching topics` : "No topics found. Try a different search.")
        : "Browse topics";
    for (const page of matches) {
        const row = document.createElement("li");
        const link = document.createElement("a");
        const name = document.createElement("strong");
        const summary = document.createElement("span");
        link.href = page.url;
        name.textContent = page.title;
        summary.textContent = page.description;
        link.append(name, summary);
        row.append(link);
        results.append(row);
    }
    selectResult(0, false);
    results.scrollTop = 0;
}

function showSearch() {
    if (!dialog.open) dialog.showModal();
    input.focus();
    input.select();
}

searchOpen.addEventListener("click", showSearch);
input.addEventListener("input", renderResults);
dialog.addEventListener("close", () => searchOpen.focus());
dialog.addEventListener("click", (event) => {
    if (event.target === dialog) {
        const bounds = dialog.getBoundingClientRect();
        if (event.clientX < bounds.left || event.clientX > bounds.right ||
            event.clientY < bounds.top || event.clientY > bounds.bottom) dialog.close();
    }
});
input.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        selectResult(selected + (event.key === "ArrowDown" ? 1 : -1));
    } else if (event.key === "Enter" && selected >= 0) {
        event.preventDefault();
        results.querySelectorAll("a")[selected]?.click();
    }
});
document.addEventListener("keydown", (event) => {
    const editing = event.target instanceof HTMLElement &&
        (event.target.matches("input, textarea, select") || event.target.isContentEditable);
    const shortcut = (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k";
    if (shortcut || (event.key === "/" && !editing && !dialog.open)) {
        event.preventDefault();
        showSearch();
    }
});
renderResults();

const menu = document.querySelector("#nav-toggle");
const nav = document.querySelector("#wiki-nav");
menu.addEventListener("click", () => {
    const open = menu.getAttribute("aria-expanded") === "false";
    menu.setAttribute("aria-expanded", String(open));
    nav.classList.toggle("is-open", open);
});

const copyStatus = document.querySelector("#copy-status");
document.querySelectorAll(".copy").forEach((button) => {
    let reset;
    button.addEventListener("click", async () => {
        const code = button.closest(".code-panel").querySelector("pre code");
        const label = button.querySelector(".copy-label");
        clearTimeout(reset);
        try {
            await navigator.clipboard.writeText(code.textContent);
            label.textContent = "Copied";
            copyStatus.textContent = "Code copied to the clipboard.";
        } catch {
            const range = document.createRange();
            range.selectNodeContents(code);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            label.textContent = "Selected";
            copyStatus.textContent = "Code selected for manual copy.";
        }
        reset = setTimeout(() => {
            label.textContent = "Copy";
            copyStatus.textContent = "";
        }, 1800);
    });
});
