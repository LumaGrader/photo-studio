// Generated from the proofing gallery template. The page a client opens: grid, large view,
// hearts, notes and "Send my picks" (copy / email / Messenger). Self-contained, works offline.
// /*GALLERY_DATA*/ is replaced with the gallery JSON.

enum ProofingTemplate {
    static let html = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex">
<title>Proofing</title>
<style>
:root {
  color-scheme: dark;
  --bg: #101214; --panel: #1a1d21; --raised: #24282d; --line: #2e3339;
  --text: #e9edf1; --soft: #9aa4ae; --accent: #30b2f7; --heart: #ff4f6d;
  --font: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
}
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--bg); color: var(--text); font-family: var(--font); -webkit-text-size-adjust: 100%; }
button { font: inherit; color: inherit; cursor: pointer; }
:focus-visible { outline: 3px solid var(--accent); outline-offset: 2px; }
header {
  position: sticky; top: 0; z-index: 5; background: rgba(16, 18, 20, 0.94);
  backdrop-filter: blur(8px); -webkit-backdrop-filter: blur(8px);
  border-bottom: 1px solid var(--line);
  padding: 14px max(16px, env(safe-area-inset-left)) 12px;
}
.head { max-width: 1400px; margin: 0 auto; display: flex; flex-wrap: wrap; align-items: center; gap: 10px 20px; }
.titles { flex: 1 1 260px; min-width: 0; }
h1 { margin: 0; font-size: 1.35rem; font-weight: 700; letter-spacing: -0.01em; }
.by { margin: 2px 0 0; color: var(--soft); font-size: 0.9rem; }
.tools { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.seg { display: inline-flex; background: var(--panel); border: 1px solid var(--line); border-radius: 999px; padding: 3px; }
.seg button { border: 0; background: none; padding: 7px 14px; border-radius: 999px; font-size: 0.92rem; color: var(--soft); }
.seg button[aria-pressed="true"] { background: var(--raised); color: var(--text); font-weight: 600; }
.send {
  border: 0; border-radius: 999px; padding: 10px 18px; background: var(--heart); color: #fff; font-weight: 700;
  display: inline-flex; align-items: center; gap: 8px; font-size: 0.95rem;
}
.send svg { width: 18px; height: 18px; }
.intro { max-width: 1400px; margin: 0 auto; padding: 16px max(16px, env(safe-area-inset-left)) 4px; color: var(--soft); font-size: 0.95rem; line-height: 1.5; }
.intro p { margin: 0; max-width: 70ch; }
.warn { color: #ffc46b; margin-top: 6px !important; }
main { max-width: 1400px; margin: 0 auto; padding: 12px max(12px, env(safe-area-inset-left)) 80px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 10px; }
@media (max-width: 560px) { .grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 6px; } }
.cell { position: relative; background: var(--panel); border-radius: 8px; overflow: hidden; aspect-ratio: 1; }
.cell > button.open { display: block; width: 100%; height: 100%; padding: 0; border: 0; background: none; }
.cell img { width: 100%; height: 100%; object-fit: contain; display: block; background: #0b0c0e; }
.cell .num { position: absolute; left: 8px; bottom: 8px; font-size: 0.75rem; color: #fff; background: rgba(0, 0, 0, 0.55); padding: 2px 7px; border-radius: 999px; pointer-events: none; }
.cell .note { position: absolute; left: 8px; top: 8px; width: 26px; height: 26px; border-radius: 50%; background: rgba(0, 0, 0, 0.55); display: grid; place-items: center; pointer-events: none; }
.cell .note[hidden] { display: none; }
.cell .note svg { width: 15px; height: 15px; fill: #fff; }
.heart {
  position: absolute; right: 6px; bottom: 6px; width: 42px; height: 42px; border: 0; border-radius: 50%;
  background: rgba(0, 0, 0, 0.5); display: grid; place-items: center;
}
.heart svg { width: 22px; height: 22px; fill: none; stroke: #fff; stroke-width: 2; }
.heart[aria-pressed="true"] svg { fill: var(--heart); stroke: var(--heart); }
.cell.fav { box-shadow: inset 0 0 0 3px var(--heart); }
.empty { color: var(--soft); text-align: center; padding: 60px 16px; }
footer { color: #5f6973; font-size: 0.8rem; text-align: center; padding: 0 16px 32px; }

/* Lightbox */
.lb { position: fixed; inset: 0; z-index: 20; background: #050607; display: none; flex-direction: column; }
.lb.on { display: flex; }
.lb-top { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 10px 14px; color: var(--soft); font-size: 0.9rem; }
.lb-top button { border: 0; background: var(--raised); border-radius: 999px; padding: 8px 14px; }
.lb-stage { flex: 1; position: relative; min-height: 0; display: flex; align-items: center; justify-content: center; touch-action: pan-y; }
.lb-stage img { max-width: 100%; max-height: 100%; object-fit: contain; user-select: none; -webkit-user-drag: none; }
.nav { position: absolute; top: 50%; transform: translateY(-50%); width: 48px; height: 64px; border: 0; background: rgba(255, 255, 255, 0.06); border-radius: 10px; font-size: 1.8rem; color: #fff; }
.nav.prev { left: 10px; } .nav.next { right: 10px; }
@media (hover: none) { .nav { display: none; } }
.lb-bar { display: flex; flex-wrap: wrap; align-items: flex-start; gap: 10px; padding: 10px 14px calc(12px + env(safe-area-inset-bottom)); background: var(--panel); border-top: 1px solid var(--line); }
.lb-heart { border: 0; border-radius: 999px; padding: 11px 18px; background: var(--raised); display: inline-flex; gap: 8px; align-items: center; font-weight: 600; }
.lb-heart svg { width: 20px; height: 20px; fill: none; stroke: currentColor; stroke-width: 2; }
.lb-heart[aria-pressed="true"] { background: var(--heart); color: #fff; }
.lb-heart[aria-pressed="true"] svg { fill: #fff; }
.lb-bar textarea { flex: 1 1 260px; min-height: 44px; max-height: 120px; resize: vertical; background: var(--bg); color: var(--text); border: 1px solid var(--line); border-radius: 10px; padding: 10px 12px; font: inherit; font-size: 0.95rem; }

/* Send dialog */
dialog { border: 1px solid var(--line); border-radius: 14px; background: var(--panel); color: var(--text); width: min(560px, calc(100vw - 24px)); padding: 0; }
dialog::backdrop { background: rgba(0, 0, 0, 0.7); }
.dlg { padding: 22px; display: grid; gap: 12px; }
.dlg h2 { margin: 0; font-size: 1.25rem; }
.dlg p { margin: 0; color: var(--soft); line-height: 1.5; font-size: 0.95rem; }
.dlg label { font-size: 0.9rem; color: var(--soft); display: grid; gap: 6px; }
.dlg input, .dlg textarea { background: var(--bg); color: var(--text); border: 1px solid var(--line); border-radius: 10px; padding: 10px 12px; font: inherit; font-size: 0.95rem; }
.dlg textarea { min-height: 170px; font-family: ui-monospace, Menlo, monospace; font-size: 0.82rem; }
.row { display: flex; flex-wrap: wrap; gap: 8px; }
.btn { border: 0; border-radius: 10px; padding: 11px 16px; background: var(--raised); font-weight: 600; text-decoration: none; color: var(--text); display: inline-flex; align-items: center; }
.btn.primary { background: var(--accent); color: #04121f; }
.done { color: #7fdc9a; font-size: 0.9rem; min-height: 1.2em; }
</style>
</head>
<body>
<header>
  <div class="head">
    <div class="titles">
      <h1 id="title"></h1>
      <p class="by" id="by"></p>
    </div>
    <div class="tools">
      <div class="seg" role="group" aria-label="Show">
        <button type="button" id="show-all" aria-pressed="true">All <span id="count-all"></span></button>
        <button type="button" id="show-fav" aria-pressed="false">Favorites <span id="count-fav">0</span></button>
      </div>
      <button type="button" class="send" id="send-open">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M12 21s-7.5-4.6-9.6-9.2C.9 8.3 3 4.5 6.7 4.5c2.1 0 3.6 1.2 4.3 2.4.7-1.2 2.2-2.4 4.3-2.4 3.7 0 5.8 3.8 4.3 7.3C19.5 16.4 12 21 12 21z"/></svg>
        Send my picks
      </button>
    </div>
  </div>
</header>
<div class="intro">
  <p id="intro">Tap the heart on the photos you like. Open a photo to see it large and add a note. When you're done, press <b>Send my picks</b>.</p>
  <p class="warn" id="storage-warn" hidden>This browser can't save your hearts. Keep this page open until you've sent your picks.</p>
</div>
<main>
  <div class="grid" id="grid"></div>
  <p class="empty" id="empty" hidden>No favorites yet. Tap a heart to add one.</p>
</main>
<footer>Proofing gallery made with LumaGrader Photo Studio</footer>

<div class="lb" id="lb" role="dialog" aria-modal="true" aria-label="Photo">
  <div class="lb-top"><span id="lb-pos"></span><button type="button" id="lb-close">Close</button></div>
  <div class="lb-stage" id="lb-stage">
    <img id="lb-img" alt="">
    <button type="button" class="nav prev" id="lb-prev" aria-label="Previous photo">‹</button>
    <button type="button" class="nav next" id="lb-next" aria-label="Next photo">›</button>
  </div>
  <div class="lb-bar">
    <button type="button" class="lb-heart" id="lb-heart" aria-pressed="false">
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 21s-7.5-4.6-9.6-9.2C.9 8.3 3 4.5 6.7 4.5c2.1 0 3.6 1.2 4.3 2.4.7-1.2 2.2-2.4 4.3-2.4 3.7 0 5.8 3.8 4.3 7.3C19.5 16.4 12 21 12 21z"/></svg>
      <span>Favorite</span>
    </button>
    <textarea id="lb-note" placeholder="Add a note for this photo (optional), e.g. “crop tighter” or “remove the person behind”" aria-label="Note for this photo"></textarea>
  </div>
</div>

<dialog id="send">
  <form method="dialog" class="dlg">
    <h2>Send my picks</h2>
    <p id="send-summary"></p>
    <label>Your name <input id="client-name" autocomplete="name" placeholder="e.g. Ana and Mark"></label>
    <textarea id="picks-text" readonly aria-label="Your picks"></textarea>
    <div class="row">
      <button type="button" class="btn primary" id="copy">Copy list</button>
      <a class="btn" id="mail" hidden>Send by email</a>
      <a class="btn" id="messenger" hidden target="_blank" rel="noopener">Copy and open Messenger</a>
      <button class="btn" value="close">Close</button>
    </div>
    <p class="done" id="copied" aria-live="polite"></p>
    <p id="send-how"></p>
  </form>
</dialog>

<script>
window.GALLERY = /*GALLERY_DATA*/;
</script>
<script>
(() => {
  const G = window.GALLERY
  const KEY = 'lumagrader-proofing-' + G.id
  const $ = (id) => document.getElementById(id)
  let state = { fav: {}, note: {}, name: '' }
  let canStore = true
  try {
    const saved = JSON.parse(localStorage.getItem(KEY) || 'null')
    if (saved && typeof saved === 'object') state = Object.assign(state, saved)
    localStorage.setItem(KEY + '-test', '1')
    localStorage.removeItem(KEY + '-test')
  } catch (e) { canStore = false }
  if (!canStore) $('storage-warn').hidden = false
  const save = () => { if (!canStore) return; try { localStorage.setItem(KEY, JSON.stringify(state)) } catch (e) {} }

  document.title = G.title + ' · Proofing'
  $('title').textContent = G.title
  $('by').textContent = [G.photographer ? 'Photos by ' + G.photographer : '', G.photos.length + ' photos'].filter(Boolean).join(' · ')
  if (G.message) $('intro').textContent = G.message
  $('count-all').textContent = G.photos.length

  const heartSvg = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 21s-7.5-4.6-9.6-9.2C.9 8.3 3 4.5 6.7 4.5c2.1 0 3.6 1.2 4.3 2.4.7-1.2 2.2-2.4 4.3-2.4 3.7 0 5.8 3.8 4.3 7.3C19.5 16.4 12 21 12 21z"/></svg>'
  const noteSvg = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 4h16v12H8l-4 4z"/></svg>'
  let onlyFav = false
  const cells = new Map()

  function build() {
    const grid = $('grid')
    for (const p of G.photos) {
      const cell = document.createElement('div')
      cell.className = 'cell'
      const open = document.createElement('button')
      open.type = 'button'; open.className = 'open'
      open.setAttribute('aria-label', 'Open photo ' + p.n)
      const img = document.createElement('img')
      img.loading = 'lazy'; img.decoding = 'async'; img.alt = 'Photo ' + p.n
      img.src = 'thumbs/' + p.file
      open.append(img)
      open.addEventListener('click', () => show(G.photos.indexOf(p)))
      const num = document.createElement('span'); num.className = 'num'; num.textContent = p.n
      const note = document.createElement('span'); note.className = 'note'; note.innerHTML = noteSvg; note.title = 'Has a note'
      const heart = document.createElement('button')
      heart.type = 'button'; heart.className = 'heart'; heart.innerHTML = heartSvg
      heart.addEventListener('click', () => toggle(p.n))
      cell.append(open, num, note, heart)
      grid.append(cell)
      cells.set(p.n, { cell, heart, note })
    }
    refresh()
  }

  function refresh() {
    let favs = 0
    for (const p of G.photos) {
      const c = cells.get(p.n)
      const isFav = !!state.fav[p.n]
      if (isFav) favs++
      c.heart.setAttribute('aria-pressed', String(isFav))
      c.heart.setAttribute('aria-label', (isFav ? 'Remove photo ' : 'Favorite photo ') + p.n)
      c.cell.classList.toggle('fav', isFav)
      c.note.hidden = !(state.note[p.n] || '').trim()
      c.cell.hidden = onlyFav && !isFav
    }
    $('count-fav').textContent = favs
    $('empty').hidden = !(onlyFav && favs === 0)
  }

  function toggle(n) {
    if (state.fav[n]) delete state.fav[n]; else state.fav[n] = true
    save(); refresh()
    if (current >= 0 && G.photos[current].n === n) paintLightbox()
  }

  $('show-all').addEventListener('click', () => setFilter(false))
  $('show-fav').addEventListener('click', () => setFilter(true))
  function setFilter(fav) {
    onlyFav = fav
    $('show-all').setAttribute('aria-pressed', String(!fav))
    $('show-fav').setAttribute('aria-pressed', String(fav))
    refresh()
  }

  // Lightbox
  let current = -1
  function list() { return onlyFav ? G.photos.filter((p) => state.fav[p.n]) : G.photos }
  function show(index) {
    current = index
    $('lb').classList.add('on')
    document.body.style.overflow = 'hidden'
    paintLightbox()
    $('lb-close').focus()
  }
  function paintLightbox() {
    const p = G.photos[current]
    const l = list()
    $('lb-img').src = 'photos/' + p.file
    $('lb-img').alt = 'Photo ' + p.n
    $('lb-pos').textContent = 'Photo ' + p.n + ' · ' + (l.indexOf(p) + 1) + ' of ' + l.length
    const isFav = !!state.fav[p.n]
    $('lb-heart').setAttribute('aria-pressed', String(isFav))
    $('lb-heart').querySelector('span').textContent = isFav ? 'Favorited' : 'Favorite'
    $('lb-note').value = state.note[p.n] || ''
    const next = l[(l.indexOf(p) + 1) % l.length]
    if (next) { const pre = new Image(); pre.src = 'photos/' + next.file }
  }
  function step(delta) {
    const l = list()
    if (!l.length) return
    const i = l.indexOf(G.photos[current])
    const target = l[(i + delta + l.length) % l.length]
    current = G.photos.indexOf(target)
    paintLightbox()
  }
  function close() {
    $('lb').classList.remove('on')
    document.body.style.overflow = ''
    const c = cells.get(G.photos[current].n)
    current = -1
    if (c) c.heart.focus()
  }
  $('lb-close').addEventListener('click', close)
  $('lb-prev').addEventListener('click', () => step(-1))
  $('lb-next').addEventListener('click', () => step(1))
  $('lb-heart').addEventListener('click', () => toggle(G.photos[current].n))
  $('lb-note').addEventListener('input', (e) => {
    const n = G.photos[current].n
    const v = e.target.value
    if (v.trim()) state.note[n] = v; else delete state.note[n]
    save(); refresh()
  })
  document.addEventListener('keydown', (e) => {
    if (current < 0 || e.target.tagName === 'TEXTAREA' || e.target.tagName === 'INPUT') return
    if (e.key === 'ArrowRight') step(1)
    else if (e.key === 'ArrowLeft') step(-1)
    else if (e.key === 'Escape') close()
    else if (e.key === 'f' || e.key === 'h') toggle(G.photos[current].n)
  })
  let touchX = null
  $('lb-stage').addEventListener('touchstart', (e) => { touchX = e.touches[0].clientX }, { passive: true })
  $('lb-stage').addEventListener('touchend', (e) => {
    if (touchX === null) return
    const dx = e.changedTouches[0].clientX - touchX
    touchX = null
    if (Math.abs(dx) > 50) step(dx < 0 ? 1 : -1)
  })

  // Send
  function picksText() {
    const favs = G.photos.filter((p) => state.fav[p.n])
    const noted = G.photos.filter((p) => !state.fav[p.n] && (state.note[p.n] || '').trim())
    const line = (p) => {
      const note = (state.note[p.n] || '').replace(/\s+/g, ' ').trim()
      return '#' + String(p.n).padStart(3, '0') + ' ' + p.name + (note ? ' — ' + note : '')
    }
    const out = [
      'LumaGrader picks · ' + G.title,
      'Gallery ID: ' + G.id,
      'From: ' + (state.name.trim() || '(no name)'),
      favs.length + ' favorite' + (favs.length === 1 ? '' : 's'),
      '',
      ...favs.map(line),
    ]
    if (noted.length) out.push('', 'Notes on other photos:', ...noted.map(line))
    return out.join('\n')
  }
  function paintSend() {
    const n = Object.keys(state.fav).length
    $('send-summary').textContent = n ? 'You picked ' + n + ' photo' + (n === 1 ? '' : 's') + '. Add your name, then send the list to ' + (G.photographer || 'your photographer') + '.'
                                      : 'You haven’t picked any photos yet. Tap the hearts first, then come back here.'
    const text = picksText()
    $('picks-text').value = text
    if (G.email) {
      $('mail').hidden = false
      $('mail').href = 'mailto:' + encodeURIComponent(G.email) + '?subject=' + encodeURIComponent('My picks · ' + G.title) + '&body=' + encodeURIComponent(text)
    }
    if (G.messenger) $('messenger').hidden = false
    $('send-how').textContent = G.messenger || G.email
      ? 'Messenger can’t fill in the message for you: after it opens, paste the list (long-press › Paste, or ⌘V / Ctrl+V) and send.'
      : 'Copy the list and paste it in a message to ' + (G.photographer || 'your photographer') + ' (Messenger, Viber, email…).'
  }
  $('client-name').value = state.name || ''
  $('client-name').addEventListener('input', (e) => { state.name = e.target.value; save(); paintSend() })
  $('send-open').addEventListener('click', () => { $('copied').textContent = ''; paintSend(); $('send').showModal() })
  async function copy() {
    const text = $('picks-text').value
    try { await navigator.clipboard.writeText(text); $('copied').textContent = 'Copied. Now paste it in your message.'; return true }
    catch (e) {
      $('picks-text').focus(); $('picks-text').select()
      try { document.execCommand('copy'); $('copied').textContent = 'Copied. Now paste it in your message.'; return true }
      catch (e2) { $('copied').textContent = 'Select the text above and copy it.'; return false }
    }
  }
  $('copy').addEventListener('click', copy)
  $('messenger').addEventListener('click', () => { copy() })
  if (G.messenger) $('messenger').href = 'https://m.me/' + encodeURIComponent(G.messenger)

  build()
})()
</script>
</body>
</html>
"""#
}
