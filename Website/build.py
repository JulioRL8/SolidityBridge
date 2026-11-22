"""Build the static documentation from the public integration guide."""

from html import escape
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parent
DIST = ROOT / "dist"
CONTENT = ROOT / "content"

GROUPS = [
    ("Get started", [
        ("installation", "Install the package", "install-and-configure", "Add SolidityBridge to Xcode and connect to an Ethereum node."),
        ("counter", "Counter walkthrough", "run-the-counter-example", "Run Counter.sol on Anvil and try it in the SwiftUI demo."),
    ]),
    ("Work with contracts", [
        ("abi", "ABI and contract calls", "use-the-dynamic-abi-api", "Read state, simulate calls, and map Solidity types to Swift."),
        ("bindings", "Typed Swift bindings", "generate-typed-bindings", "Generate contract-specific Swift types from your ABI."),
        ("transactions", "Transactions and wallets", "sign-and-send-transactions", "Prepare, sign, send, and track EIP-1559 transactions."),
        ("events", "Events and logs", "read-and-watch-events", "Filter, page, and watch contract events across blocks."),
        ("deployment", "Deploy a contract", "deploy-a-contract", "Submit creation bytecode and retrieve the deployed address."),
    ]),
    ("Reference", [
        ("errors", "Error handling", "handle-errors", "Decode Solidity reverts and handle RPC, receipt, and event errors."),
        ("testing", "Testing and troubleshooting", "test-and-troubleshoot", "Test with a mock transport, run Anvil, and debug integrations."),
        ("reference", "API reference", "api-reference", "Find public types, protocols, and entry points."),
    ]),
]
PAGES = [(slug, title, key, description, group) for group, entries in GROUPS for slug, title, key, description in entries]
LINKS = {f"#{key}": f"{slug}.html" for slug, _, key, _, _ in PAGES}
LINKS.update({
    "../Examples/Demo/SolidityBridgeDemo.xcodeproj": "counter.html#open-the-demo",
    "../Examples/Counter.sol": "examples/Counter.sol",
    "../Tests/SolidityBridgeTests/ContractTests.swift": "examples/ContractTests.swift",
    "../PLAN.md#estado-de-implementacion": "testing.html#validation-status",
})


def anchor(text):
    return re.sub(r"[^a-z0-9 -]", "", text.lower()).replace(" ", "-")


def inline(text):
    tokens = re.compile(r"`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)|\*\*([^*]+)\*\*")
    parts = []
    cursor = 0
    for match in tokens.finditer(text):
        parts.append(escape(text[cursor:match.start()]))
        code, label, target, bold = match.groups()
        if code is not None:
            parts.append(f"<code>{escape(code)}</code>")
        elif label is not None:
            resolved = LINKS.get(target, target)
            if not resolved.startswith("https://") and target not in LINKS:
                raise ValueError(f"Unmapped link: {target}")
            parts.append(f'<a href="{escape(resolved, quote=True)}">{inline(label)}</a>')
        else:
            parts.append(f"<strong>{escape(bold)}</strong>")
        cursor = match.end()
    parts.append(escape(text[cursor:]))
    return "".join(parts)


SWIFT_TOKENS = re.compile(
    r"//[^\n]*|\"(?:\\.|[^\"\\])*\"|"
    r"\b(?:import|let|var|func|struct|init|async|await|throws|throw|try|guard|else|return|for|in|"
    r"case|switch|do|catch|private|public|if|nil|self|any)\b|"
    r"\b[A-Z][A-Za-z0-9_]*\b|\b(?:0x[a-fA-F0-9]+|[0-9][0-9_]*)\b"
)


def highlight(code, language):
    if language != "swift":
        return escape(code)

    def classify(match):
        token = match.group()
        kind = (
            "comment" if token.startswith("//") else "string" if token.startswith('"')
            else "type" if token[0].isupper() else "number" if token[0].isdigit() else "keyword"
        )
        return f'<span class="syntax-{kind}">{escape(token)}</span>'

    parts = []
    cursor = 0
    for match in SWIFT_TOKENS.finditer(code):
        parts.extend((escape(code[cursor:match.start()]), classify(match)))
        cursor = match.end()
    parts.append(escape(code[cursor:]))
    return "".join(parts)


def code_block(code, language):
    label = {"swift": "Swift", "bash": "Terminal"}.get(language, "Code")
    return (
        f'<div class="code-panel"><div class="code-bar"><span>{label}</span>'
        '<button class="copy" type="button" aria-label="Copy code"><span class="copy-icon" '
        'aria-hidden="true"></span><span class="copy-label">Copy</span></button></div>'
        f'<pre tabindex="0"><code>{highlight(code, language)}</code></pre></div>'
    )


def render(markdown):
    lines = markdown.splitlines()
    result, headings = [], []
    index = 0
    while index < len(lines):
        line = lines[index]
        if not line.strip():
            index += 1
        elif line.startswith("```"):
            language = line[3:].strip()
            end = index + 1
            while end < len(lines) and lines[end] != "```":
                end += 1
            if end == len(lines):
                raise ValueError("Unclosed code fence")
            result.append(code_block("\n".join(lines[index + 1:end]), language))
            index = end + 1
        elif line.startswith("### "):
            title = line[4:]
            key = anchor(title)
            headings.append((key, title))
            result.append(f'<h2 id="{key}">{inline(title)}</h2>')
            index += 1
        elif line.startswith("| "):
            rows = []
            while index < len(lines) and lines[index].startswith("| "):
                rows.append([cell.strip() for cell in lines[index][1:-1].split("|")])
                index += 1
            def row(cells, tag):
                return "<tr>" + "".join(f"<{tag}>{inline(cell)}</{tag}>" for cell in cells) + "</tr>"
            result.append(
                '<div class="table-scroll" tabindex="0"><table><thead>' + row(rows[0], "th")
                + "</thead><tbody>" + "".join(row(cells, "td") for cells in rows[2:]) + "</tbody></table></div>"
            )
        elif line.startswith("- "):
            result.append("<ul>")
            while index < len(lines) and lines[index].startswith("- "):
                result.append(f"<li>{inline(lines[index][2:])}</li>")
                index += 1
            result.append("</ul>")
        else:
            paragraph = []
            while index < len(lines) and lines[index].strip() and not lines[index].startswith(("```", "### ", "| ", "- ")):
                paragraph.append(lines[index])
                index += 1
            result.append(f"<p>{inline(' '.join(paragraph))}</p>")
    return "\n".join(result), headings


def navigation(current):
    root_state = ' aria-current="page"' if current == "index" else ""
    html = [f'<a class="overview" href="index.html"{root_state}><span aria-hidden="true">⌂</span> Overview</a>']
    for group, entries in GROUPS:
        html.append(f"<h2>{group}</h2><ul>")
        for slug, title, _, _ in entries:
            state = ' aria-current="page"' if current == slug else ""
            html.append(f'<li><a href="{slug}.html"{state}>{escape(title)}</a></li>')
        html.append("</ul>")
    return "".join(html)


def frame(slug, title, description, body, outline):
    current = "SolidityBridge Docs" if slug == "index" else f"{title} · SolidityBridge Docs"
    return f"""<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="{escape(description, quote=True)}">
    <meta name="theme-color" content="#10111b">
    <title>{escape(current)}</title>
    <link rel="stylesheet" href="assets/wiki.css">
    <script defer src="assets/search-index.js"></script>
    <script defer src="assets/wiki.js"></script>
</head>
<body>
    <a class="skip" href="#main-content">Skip to content</a>
    <header class="topbar">
        <div class="topbar-inner">
            <a class="brand" href="index.html"><span class="brand-icon" aria-hidden="true"><span></span></span><span>SolidityBridge <small>Docs</small></span></a>
            <div class="topbar-actions">
                <button type="button" id="search-open" class="search-open" aria-label="Search documentation"><span class="search-icon" aria-hidden="true"></span><span>Search docs</span><kbd>⌘ K</kbd></button>
                <button type="button" id="nav-toggle" aria-expanded="false" aria-controls="wiki-nav">Menu</button>
            </div>
        </div>
    </header>
    <div class="shell">
        <nav class="sidebar" id="wiki-nav" aria-label="Documentation">
            {navigation(slug)}
        </nav>
        <main id="main-content" class="{'home' if slug == 'index' else 'article'}" tabindex="-1">
            {body}
            <footer>SolidityBridge documentation <span>Swift 6 · iOS 16+ · macOS 13+</span></footer>
        </main>
        {outline}
    </div>
    <dialog id="search-dialog" aria-labelledby="search-title">
        <div class="dialog-header">
            <h2 id="search-title">Search documentation</h2>
            <form method="dialog"><button type="submit" aria-label="Close search">Close</button></form>
        </div>
        <label class="search-field"><span class="search-icon" aria-hidden="true"></span><input id="search-input" type="search" placeholder="Try wallets, events, or UInt256" autocomplete="off" aria-label="Search documentation"></label>
        <p id="search-status" class="search-status" aria-live="polite">Browse topics</p>
        <ul id="search-results" class="search-results"></ul>
        <div class="dialog-hint">Use <kbd>↑</kbd> <kbd>↓</kbd> to select and <kbd>Enter</kbd> to open.</div>
    </dialog>
    <div id="copy-status" class="visually-hidden" role="status"></div>
</body>
</html>
"""


def home():
    descriptions = {slug: description for slug, _, _, description, _ in PAGES}
    cards = [
        ("installation", "Install the package", "cube"),
        ("counter", "Counter walkthrough", "terminal"),
        ("bindings", "Typed Swift bindings", "brackets"),
        ("transactions", "Transactions and wallets", "wallet"),
        ("events", "Events and logs", "signal"),
        ("reference", "API reference", "book"),
    ]
    items = "".join(
        f'<a class="topic-card" href="{slug}.html"><span class="tile-icon {icon}" aria-hidden="true"></span>'
        f'<strong>{title}</strong><span>{descriptions[slug]}</span></a>'
        for slug, title, icon in cards
    )
    sample = code_block(
        'import SolidityBridge\n\nlet client = try EthereumClient(\n    chainID: 31_337, rpcURL: rpcURL\n)\nlet contract = client.contract(at: address, abi: abi)\nlet value = try await contract.read("value()")',
        "swift",
    )
    return f"""
        <section class="hero" aria-labelledby="hero-title">
            <div class="hero-copy">
                <div class="eyebrow">SOLIDITYBRIDGE DOCUMENTATION</div>
                <h1 id="hero-title">Ethereum contracts,<br><em>in Swift.</em></h1>
                <p>Read, simulate, and send transactions to Solidity contracts from your iOS or macOS app.</p>
                <div class="hero-actions"><a href="installation.html" class="primary">Get started</a><a href="reference.html" class="secondary">API reference</a></div>
            </div>
            <div class="hero-example">{sample}</div>
        </section>
        <section class="topic-section" aria-labelledby="topic-title">
            <h2 id="topic-title">Explore the docs</h2>
            <div class="topics">{items}</div>
        </section>
    """


def write_page(filename, title, description, body, outline=""):
    slug = filename.removesuffix(".html")
    document = frame(slug, title, description, body, outline)
    document = re.sub(r"(?m)^[ \t]+$", "", document)
    (DIST / filename).write_text(document, encoding="utf-8")


def build():
    DIST.mkdir(exist_ok=True)
    shutil.copytree(ROOT / "assets", DIST / "assets", dirs_exist_ok=True)
    examples = DIST / "examples"
    examples.mkdir(exist_ok=True)
    for filename in ("Counter.sol", "ContractTests.swift"):
        shutil.copyfile(CONTENT / filename, examples / filename)
    guide = (CONTENT / "DEVELOPERS.md").read_text(encoding="utf-8")
    sections = re.split(r"^## (.+)$", guide, flags=re.M)
    content = {anchor(title): markdown.strip() for title, markdown in zip(sections[1::2], sections[2::2])}
    content["test-and-troubleshoot"] += (
        "\n\n### Validation status\n\n"
        "The core tests use a mock RPC transport and Foundry reference vectors. The demo compiled "
        "for device and simulator SDKs. The pinned local signing dependency, the app running in Xcode, "
        "and complete Anvil and Sepolia integration runs remain to be verified."
    )
    write_page("index.html", "Overview", "SolidityBridge developer documentation for iOS and macOS.", home())
    search = []
    for position, (slug, title, key, description, group) in enumerate(PAGES):
        markdown = content[key]
        body, headings = render(markdown)
        if slug == "counter":
            body = body.replace('<p>Copy the contract address', '<h2 id="open-the-demo">Open the demo</h2><p>Copy the contract address', 1)
            headings.append(("open-the-demo", "Open the demo"))
        pagination = []
        for offset, label in [(-1, "Previous"), (1, "Next")]:
            if 0 <= position + offset < len(PAGES):
                neighbor, name, *_ = PAGES[position + offset]
                pagination.append(f'<a class="pager-{label.lower()}" href="{neighbor}.html"><span>{label}</span><strong>{escape(name)}</strong></a>')
        pager = '<nav class="pager" aria-label="Adjacent topics">' + "".join(pagination) + "</nav>"
        article = f'<div class="eyebrow">{group}</div><h1>{title}</h1><p class="intro">{description}</p><div class="prose">{body}</div>{pager}'
        outline = ""
        if headings:
            items = "".join(f'<li><a href="#{key}">{escape(heading)}</a></li>' for key, heading in headings)
            outline = f'<aside class="outline"><nav aria-label="On this page"><h2>On this page</h2><ul>{items}</ul></nav></aside>'
        write_page(f"{slug}.html", title, description, article, outline)
        search.append({"title": title, "description": description, "group": group, "url": f"{slug}.html", "text": markdown})
    index = json.dumps(search, ensure_ascii=False)
    (DIST / "assets" / "search-index.js").write_text(f"globalThis.solidityBridgePages = {index};\n", encoding="utf-8")


if __name__ == "__main__":
    build()
