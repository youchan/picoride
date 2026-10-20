// Prism.js + textarea オーバーレイ方式のシンプルなコードエディタ。
// picoruby.org/terminal の File Editor (PicoModem) と同じ構造:
//   textarea(透明・キャレットのみ表示) の下に、Prismでハイライトした <pre><code> を重ねて表示する。
// ビルドステップ不要(Prism.jsは <script> タグ読み込みでグローバルに window.Prism を公開する)。

(function () {
  "use strict";

  const fileListEl = document.getElementById("file-list");
  const currentFileEl = document.getElementById("current-file");
  const saveBtn = document.getElementById("save-btn");
  const statusEl = document.getElementById("status");

  const textarea = document.getElementById("editor");
  const highlightContent = document.getElementById("highlight-content");
  const lineNumbersInner = document.getElementById("line-numbers-inner");
  const scrollArea = document.querySelector(".editor-scroll-area");
  const lineNumbers = document.getElementById("line-numbers");

  let currentPath = null;
  let savedContent = "";
  let currentLanguage = null; // Prism.languages.xxx
  let currentLanguageName = null; // "ruby" | "c"

  // 拡張子 -> Prism言語のマッピング
  function languageFor(path) {
    const ext = path.split(".").pop().toLowerCase();
    switch (ext) {
      case "rb":
        return { grammar: Prism.languages.ruby, name: "ruby" };
      case "c":
      case "h":
        return { grammar: Prism.languages.c, name: "c" };
      default:
        return { grammar: Prism.languages.plain || {}, name: "none" };
    }
  }

  function iconFor(path) {
    return path.split(".").pop().toLowerCase();
  }

  function setStatus(message, kind) {
    statusEl.textContent = message;
    statusEl.className = "status" + (kind ? " " + kind : "");
    if (message) {
      setTimeout(() => {
        if (statusEl.textContent === message) {
          statusEl.textContent = "";
          statusEl.className = "status";
        }
      }, 2500);
    }
  }

  // ---- ハイライト & 行番号の再描画 ----

  function escapeHtml(text) {
    return text
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  function renderHighlight() {
    const code = textarea.value;

    if (currentLanguage && currentLanguageName !== "none") {
      highlightContent.innerHTML = Prism.highlight(code, currentLanguage, currentLanguageName);
    } else {
      highlightContent.innerHTML = escapeHtml(code);
    }

    // textareaの末尾に改行がある場合、<pre>の高さがずれないよう調整用の改行を足す
    if (code.endsWith("\n")) {
      highlightContent.innerHTML += "\n";
    }

    renderLineNumbers(code);
  }

  function renderLineNumbers(code) {
    const lineCount = code.length === 0 ? 1 : code.split("\n").length;
    const currentCount = lineNumbersInner.childElementCount;

    if (currentCount < lineCount) {
      const fragment = document.createDocumentFragment();
      for (let i = currentCount + 1; i <= lineCount; i++) {
        const div = document.createElement("div");
        div.textContent = String(i);
        fragment.appendChild(div);
      }
      lineNumbersInner.appendChild(fragment);
    } else if (currentCount > lineCount) {
      for (let i = currentCount; i > lineCount; i--) {
        lineNumbersInner.removeChild(lineNumbersInner.lastChild);
      }
    }
  }

  function syncScroll() {
    // highlight-layer(<pre>)は#editor(<textarea>)と同じグリッドセルに重なっており、
    // どちらも .editor-scroll-area のスクロールに自動で追従するため、JSでの同期は不要。
    // 行番号だけは独立したカラムなので、ここでスクロール位置を合わせる。
    lineNumbers.scrollTop = scrollArea.scrollTop;
  }

  function updateDirtyState() {
    const dirty = textarea.value !== savedContent;
    saveBtn.disabled = !currentPath || !dirty;
  }

  textarea.addEventListener("input", () => {
    renderHighlight();
    updateDirtyState();
  });

  scrollArea.addEventListener("scroll", syncScroll);

  // Tabキーでインデント挿入(デフォルトのフォーカス移動を止める)
  textarea.addEventListener("keydown", (e) => {
    if (e.key === "Tab") {
      e.preventDefault();
      const start = textarea.selectionStart;
      const end = textarea.selectionEnd;
      textarea.value = textarea.value.slice(0, start) + "  " + textarea.value.slice(end);
      textarea.selectionStart = textarea.selectionEnd = start + 2;
      renderHighlight();
      updateDirtyState();
    }
  });

  // ---- ファイル一覧・読み込み・保存 ----

  async function loadFileList() {
    try {
      const res = await fetch("/api/files");
      if (!res.ok) throw new Error("failed to load file list");
      const files = await res.json();

      fileListEl.innerHTML = "";

      if (files.length === 0) {
        const li = document.createElement("li");
        li.className = "empty";
        li.textContent = "編集可能なファイルがありません";
        fileListEl.appendChild(li);
        return;
      }

      for (const path of files) {
        const li = document.createElement("li");
        li.dataset.path = path;

        const icon = document.createElement("span");
        icon.className = `file-icon ${iconFor(path)}`;
        icon.textContent = iconFor(path).slice(0, 1).toUpperCase();

        const label = document.createElement("span");
        label.textContent = path;

        li.appendChild(icon);
        li.appendChild(label);
        li.addEventListener("click", () => openFile(path));

        fileListEl.appendChild(li);
      }
    } catch (err) {
      fileListEl.innerHTML = "";
      const li = document.createElement("li");
      li.className = "empty";
      li.textContent = "ファイル一覧の取得に失敗しました";
      fileListEl.appendChild(li);
      console.error(err);
    }
  }

  async function openFile(path) {
    try {
      setStatus("読み込み中...", "");
      const res = await fetch(`/api/file?path=${encodeURIComponent(path)}`);
      if (!res.ok) {
        const err = await res.json();
        throw new Error(err.error || "failed to load file");
      }
      const data = await res.json();

      currentPath = data.path;
      savedContent = data.content;

      const lang = languageFor(data.path);
      currentLanguage = lang.grammar;
      currentLanguageName = lang.name;

      textarea.value = data.content;
      textarea.disabled = false;
      renderHighlight();

      currentFileEl.textContent = data.path;
      updateDirtyState();
      setStatus("", "");

      for (const li of fileListEl.querySelectorAll("li")) {
        li.classList.toggle("active", li.dataset.path === path);
      }

      textarea.focus();
    } catch (err) {
      setStatus("読み込みエラー", "error");
      console.error(err);
    }
  }

  async function saveFile() {
    if (!currentPath) return;

    const content = textarea.value;

    try {
      saveBtn.disabled = true;
      setStatus("保存中...", "");

      const res = await fetch("/api/file", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: currentPath, content }),
      });

      if (!res.ok) {
        const err = await res.json();
        throw new Error(err.error || "failed to save file");
      }

      savedContent = content;
      setStatus("保存しました", "ok");
      updateDirtyState();
    } catch (err) {
      setStatus("保存に失敗しました", "error");
      saveBtn.disabled = false;
      console.error(err);
    }
  }

  saveBtn.addEventListener("click", saveFile);

  // Ctrl/Cmd + S で保存
  window.addEventListener("keydown", (e) => {
    const isSaveShortcut = (e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s";
    if (isSaveShortcut) {
      e.preventDefault();
      saveFile();
    }
  });

  renderLineNumbers("");
  loadFileList();
})();
