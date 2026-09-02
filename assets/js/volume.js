// One volume setting for everything Fanfarr plays.
//
// The theme player and the YouTube preview are unrelated pieces of machinery --
// an HTMLAudioElement and a cross-origin iframe -- and left alone they each
// keep their own idea of how loud things should be. Comparing a candidate
// against what was written is the whole workflow on the item page, so a
// comparison where one side is twice as loud as the other is worse than
// useless. Both read and write this, and it survives a reload.
const LEVEL_KEY = "fanfarr:volume"
const MUTED_KEY = "fanfarr:muted"

// Loud enough to judge a track by, quiet enough not to startle anyone who
// opened the page expecting silence.
const DEFAULT_LEVEL = 0.7

const listeners = new Set()

const clamp = (value) => Math.min(Math.max(value, 0), 1)

// Storage throws rather than returning null in a few real situations -- a
// private window, a browser set to block site data -- so every access is
// guarded and falls back to the default rather than taking the player down.
const read = (key) => {
  try {
    return window.localStorage.getItem(key)
  } catch (_error) {
    return null
  }
}

const write = (key, value) => {
  try {
    window.localStorage.setItem(key, value)
  } catch (_error) {
    // A player that cannot remember the volume still has to play.
  }
}

export const Volume = {
  // 0..1, the scale HTMLAudioElement uses. YouTube wants 0..100 and converts
  // at its own edge.
  level() {
    const stored = Number(read(LEVEL_KEY))
    return Number.isFinite(stored) && read(LEVEL_KEY) !== null ? clamp(stored) : DEFAULT_LEVEL
  },

  muted() {
    return read(MUTED_KEY) === "true"
  },

  set({level, muted}) {
    if (level !== undefined) write(LEVEL_KEY, String(clamp(level)))
    if (muted !== undefined) write(MUTED_KEY, String(Boolean(muted)))

    const state = {level: this.level(), muted: this.muted()}
    listeners.forEach((listener) => listener(state))
  },

  // Returns its own unsubscribe: a hook that is destroyed and remounted --
  // which the theme player does on every new download -- would otherwise leave
  // a listener holding a detached element.
  subscribe(listener) {
    listeners.add(listener)
    listener({level: this.level(), muted: this.muted()})
    return () => listeners.delete(listener)
  }
}
