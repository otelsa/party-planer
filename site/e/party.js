// Haelt die offene Seite aktuell: fragt alle paar Sekunden einen winzigen Endpunkt
// nach dem Aenderungsstand und tauscht nur dann die Listen aus. Das Formular wird
// nie angefasst, damit niemandem die Eingabe unter den Fingern verschwindet.
// Ohne JavaScript bleibt die Seite voll benutzbar, nur eben nicht selbst aktualisierend.
(() => {
  const live = document.getElementById('live')
  const hinweis = document.getElementById('frisch')
  if (!live) return

  const PAUSE_AKTIV = 8000      // Seite im Blick
  const PAUSE_RUHE = 60000      // Tab im Hintergrund
  let stand = live.dataset.stand
  let timer = null

  const zeigeHinweis = () => {
    if (!hinweis) return
    hinweis.hidden = false
    clearTimeout(hinweis._t)
    hinweis._t = setTimeout(() => { hinweis.hidden = true }, 4000)
  }

  const holen = async () => {
    try {
      const antwort = await fetch('/party/stand', { headers: { Accept: 'application/json' } })
      if (!antwort.ok) return
      const { stand: neu } = await antwort.json()
      if (!neu || neu === stand) return
      const teil = await fetch('/party/listen')
      if (!teil.ok) return
      live.innerHTML = await teil.text()
      stand = neu
      live.dataset.stand = neu
      zeigeHinweis()
    } catch (e) {
      // Netz weg oder Server neu gestartet: still bleiben und es gleich wieder versuchen.
    }
  }

  const planen = () => {
    clearTimeout(timer)
    timer = setTimeout(async () => { await holen(); planen() },
      document.visibilityState === 'visible' ? PAUSE_AKTIV : PAUSE_RUHE)
  }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') holen()
    planen()
  })
  planen()
})()
