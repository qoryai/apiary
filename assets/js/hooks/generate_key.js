// Generate a key, on a node's Access key tab (`#key-generate`): the browser makes the
// node's Ed25519 key, Qory receives only its public half, and the secret is shown once, on
// the page that made it. The pure part, the key and the one event, is key_pair.js.
//
// The element is the same `<section id="key-generate">` on the form (`…/generate`) and on
// the page the server patches to once the key is added (`…/keys/:key_id/generated`), so
// this hook lives through the patch and carries the secret across it, in its own memory:
//
// - On open it checks the browser (key_pair.js `checkSupport`). Without a secure context or
//   without Ed25519 it shows `#key-generate-insecure` or `#key-generate-unsupported` and
//   turns `#key-generate-submit` off. Nothing is sent.
// - Generate key: the hook takes the form's submit (`#key-generate-form`, which has a
//   `phx-change` and no `phx-submit`), and keeps it from LiveView too, which would submit
//   such a form natively. It turns the button off and busy (its "Generating", from the
//   server's render), makes the key, and pushes `generate_key` with the label, the Stored
//   secrets choice and the public key: never the secret.
// - It holds `{secret, publicKey}` until the secret's slot shows,
//   `#key-generated-secret[data-public-key]` (in a `phx-update="ignore"`), and writes it
//   there only if the slot's public key is its own: with `textContent` into
//   `#key-generated-secret-value`, which it focuses. Then it drops its copy. A slot it
//   holds nothing for (the page reloaded, or opened again) shows
//   `#key-generated-secret-gone`, which the server renders hidden.
// - A reply without a key (the form shows why) drops the secret and turns the button back
//   on: the next Generate key makes a new pair. No reply and no slot within 15 seconds, a
//   push that fails, or the connection dropping while the secret waits for its slot, drop
//   it and show `#key-generate-lost`.
// - Leaving the page (the section goes: `destroyed`) or the browser putting it away
//   (`pagehide`, which a back-forward cache would otherwise keep) empties the slot; a key
//   still on its way then is lost, as above.
//
// The words are the server's: the notices, the gone line and the busy label are in the
// render, the notices and the gone line hidden by the class `hidden` (not the attribute,
// which the stylesheet keeps hidden whatever `show` sets). Shown and turned off with
// `this.js()`, so that a patch keeps them. Nothing here logs, stores or keeps anything
// outside this hook.

import {checkSupport, generate} from "./key_pair"

const REPLY_TIMEOUT = 15000

const FORM = "key-generate-form"
const SUBMIT = "#key-generate-submit"
const SLOT = "#key-generated-secret"
const VALUE = "#key-generated-secret-value"
const GONE = "#key-generated-secret-gone"
const NOTICES = {
  insecure: "#key-generate-insecure",
  unsupported: "#key-generate-unsupported",
  lost: "#key-generate-lost",
}

export const GenerateKey = {
  mounted() {
    this.held = null
    this.attempt = 0
    this.pending = false
    this.timer = null
    this.offline = false

    const subtle = window.crypto ? window.crypto.subtle : undefined
    this.support = checkSupport(subtle, window.isSecureContext === true).then(state => {
      if (state !== "ok") this.refuse(state)
      return state
    })

    this.onSubmit = e => {
      if (!(e.target instanceof HTMLFormElement) || e.target.id !== FORM) return
      e.preventDefault()
      e.stopPropagation()
      this.submit(e.target)
    }
    this.el.addEventListener("submit", this.onSubmit)

    // Put away (or left): a key still on its way is lost, and a shown secret is wiped.
    this.onPageHide = () => {
      if (this.held || this.pending) this.lose()
      this.clear(true)
    }
    window.addEventListener("pagehide", this.onPageHide)

    this.fill()
  },

  updated() {
    this.fill()
  },

  disconnected() {
    this.offline = true
    if (this.held || this.pending) this.lose()
  },

  reconnected() {
    this.offline = false
  },

  destroyed() {
    window.removeEventListener("pagehide", this.onPageHide)
    this.el.removeEventListener("submit", this.onSubmit)
    this.clear(false)
  },

  async submit(form) {
    if (this.pending || this.offline) return
    this.pending = true
    const attempt = ++this.attempt

    // Not here: the notice already says why, and the button is off. app.js marked it
    // busy as the form submitted; that goes.
    if ((await this.support) !== "ok" || attempt !== this.attempt || this.offline) {
      if (attempt === this.attempt) this.pending = false
      const submit = this.el.querySelector(SUBMIT)
      if (submit) {
        submit.classList.remove("is-busy")
        submit.removeAttribute("aria-busy")
      }
      return
    }
    this.busy(true)

    let made
    try {
      made = await generate({
        subtle: window.crypto.subtle,
        label: this.field(form, "label"),
        allowSecrets: this.field(form, "allow_secrets"),
        push: (event, payload) => this.pushEvent(event, payload),
      })
    } catch (e) {
      if (attempt !== this.attempt) return
      if (e && e.kind) {
        this.pending = false
        this.refuse(e.kind)
      } else {
        this.lose()
      }
      return
    }
    // Dropped meanwhile (the page went, or the connection): so is this secret.
    if (attempt !== this.attempt) return

    this.held = {secret: made.secret, publicKey: made.publicKey}
    const reply = made.reply
    made = null
    this.timer = setTimeout(() => {
      if (attempt === this.attempt && (this.held || this.pending)) this.lose()
    }, REPLY_TIMEOUT)

    this.fill()
    this.answer(attempt, reply)
  },

  // The server's reply to the key pushed: `{key_id}` once it is added, else nothing (the
  // form shows why). Read once the secret is held, so a patch that comes first finds it.
  async answer(attempt, reply) {
    let answer
    try {
      answer = await reply
    } catch (_e) {
      if (attempt === this.attempt && (this.held || this.pending)) this.lose()
      return
    }
    if (attempt !== this.attempt) return
    this.pending = false
    if (answer && answer.key_id) {
      // Its slot shows with the patch to the one-time page, if it has not already.
      this.fill()
    } else {
      // Refused: this pair is done with, and the next Generate key makes another.
      this.drop()
      this.busy(false)
    }
  },

  field(form, name) {
    if (name === "label") {
      const input = form.querySelector('[name$="[label]"]')
      return input ? input.value : ""
    }
    const chosen = form.querySelector(`[name$="[${name}]"]:checked`)
    return chosen ? chosen.value : ""
  },

  // Writes the held secret into its slot if the slot is there and is for the held key;
  // a slot this hook holds nothing for says the secret is gone.
  fill() {
    const slot = this.el.querySelector(SLOT)
    if (!slot) return
    const value = slot.querySelector(VALUE)
    if (!value) return
    const held = this.held
    if (held && slot.getAttribute("data-public-key") === held.publicKey) {
      value.textContent = held.secret
      this.drop()
      this.pending = false
      value.focus()
    } else if (value.textContent === "") {
      if (held) this.drop()
      this.show(slot.querySelector(GONE))
    }
  },

  drop() {
    this.held = null
    clearTimeout(this.timer)
    this.timer = null
  },

  // The connection or the reply failed while the key was on its way: its secret is gone.
  lose() {
    this.attempt++
    this.drop()
    this.pending = false
    this.show(this.el.querySelector(NOTICES.lost))
    this.busy(false)
  },

  // No key can be made here: the notice says why, and Generate key stays off.
  refuse(kind) {
    this.show(this.el.querySelector(NOTICES[kind] || NOTICES.unsupported))
    this.busy(false)
    const submit = this.el.querySelector(SUBMIT)
    if (submit) this.js().setAttribute(submit, "disabled", "")
  },

  // The button, off and showing its busy words while a key is made and sent, or back on.
  // app.js marks a `data-busy` button busy as any form submits; that mark is not kept
  // through a patch, so the hook takes it over with its own.
  busy(on) {
    const submit = this.el.querySelector(SUBMIT)
    if (!submit) return
    submit.classList.remove("is-busy")
    if (on) {
      this.js().setAttribute(submit, "disabled", "")
      this.js().setAttribute(submit, "aria-busy", "true")
      this.js().addClass(submit, "is-busy")
    } else {
      this.js().removeAttribute(submit, "disabled")
      this.js().removeAttribute(submit, "aria-busy")
      this.js().removeClass(submit, "is-busy")
    }
  },

  show(el) {
    if (el) this.js().show(el)
  },

  // The slot emptied and the held copy dropped: the page is going (`destroyed`), or put
  // away (`pagehide`), after which the slot says the secret is gone.
  clear(sayGone) {
    this.attempt++
    this.drop()
    this.pending = false
    const value = this.el.querySelector(VALUE)
    if (value && value.textContent !== "") {
      value.textContent = ""
      if (sayGone) this.show(this.el.querySelector(GONE))
    }
  },
}
