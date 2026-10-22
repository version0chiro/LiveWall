(() => {
  const desktop = document.querySelector(".demo-desktop");
  const time = document.querySelector("#demo-time");
  const date = document.querySelector("#demo-date");
  const year = document.querySelector("#year");
  const copyButton = document.querySelector("#copy-command");
  const buildCommand = document.querySelector("#build-command");

  const updateClock = () => {
    const now = new Date();
    if (time) {
      time.textContent = new Intl.DateTimeFormat(undefined, {
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
      }).format(now);
    }
    if (date) {
      date.textContent = new Intl.DateTimeFormat(undefined, {
        weekday: "long",
        month: "short",
        day: "2-digit",
      })
        .format(now)
        .toUpperCase()
        .replace(",", " ·");
    }
    if (year) year.textContent = String(now.getFullYear());
  };

  updateClock();
  window.setInterval(updateClock, 15_000);

  if (desktop) {
    const updatePointer = (event) => {
      const rect = desktop.getBoundingClientRect();
      const x = ((event.clientX - rect.left) / rect.width) * 100;
      const y = ((event.clientY - rect.top) / rect.height) * 100;
      desktop.style.setProperty("--pointer-x", `${Math.max(0, Math.min(100, x))}%`);
      desktop.style.setProperty("--pointer-y", `${Math.max(0, Math.min(100, y))}%`);
    };

    desktop.addEventListener("pointermove", updatePointer);
    desktop.addEventListener("pointerdown", () => desktop.focus());
    desktop.addEventListener("keydown", (event) => {
      if (event.key === "Alt") desktop.classList.add("option-active");
    });
    desktop.addEventListener("keyup", (event) => {
      if (event.key === "Alt") desktop.classList.remove("option-active");
    });
    desktop.addEventListener("blur", () => {
      desktop.classList.remove("option-active");
    });
  }

  if (copyButton && buildCommand) {
    copyButton.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(buildCommand.textContent.trim());
        copyButton.textContent = "Copied";
        window.setTimeout(() => {
          copyButton.textContent = "Copy";
        }, 1_600);
      } catch {
        const selection = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(buildCommand);
        selection.removeAllRanges();
        selection.addRange(range);
        copyButton.textContent = "Selected";
      }
    });
  }
})();
