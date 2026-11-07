const dialog = document.getElementById('image-dialog');
const dialogImage = document.getElementById('dialog-image');
const caption = document.getElementById('dialog-caption');
const errorMessage = document.getElementById('image-error');
let lastTrigger = null;

document.querySelectorAll('[data-lightbox]').forEach(link => {
  link.addEventListener('click', event => {
    // Preserve normal new-tab gestures and the no-JavaScript fallback.
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return;
    if (typeof dialog.showModal !== 'function') return;
    event.preventDefault();
    lastTrigger = link;
    errorMessage.hidden = true;
    dialogImage.hidden = false;
    dialogImage.setAttribute('aria-busy', 'true');
    dialogImage.alt = link.querySelector('img')?.alt || link.dataset.caption;
    caption.textContent = link.dataset.caption;
    dialogImage.src = link.href;
    dialog.showModal();
    document.getElementById('close-dialog').focus();
  });
});
dialogImage.addEventListener('load', () => dialogImage.setAttribute('aria-busy', 'false'));
dialogImage.addEventListener('error', () => {
  dialogImage.setAttribute('aria-busy', 'false');
  dialogImage.hidden = true;
  errorMessage.hidden = false;
});
document.getElementById('close-dialog').addEventListener('click', () => dialog.close());
dialog.addEventListener('close', () => lastTrigger?.focus());
dialog.addEventListener('click', event => {
  if (event.target !== dialog) return;
  const bounds = dialog.getBoundingClientRect();
  if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) dialog.close();
});
