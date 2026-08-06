document.addEventListener("DOMContentLoaded", () => {
  // Soft highlight for deep-linked case tabs
  if (location.hash) {
    const el = document.querySelector(location.hash);
    if (el) {
      el.style.outline = "2px solid #0f5c63";
      el.style.outlineOffset = "4px";
      setTimeout(() => {
        el.style.outline = "none";
      }, 1600);
    }
  }
});