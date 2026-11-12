defmodule ApiaryProWeb.Gettext do
  @moduledoc """
  The edition's Gettext backend: the sentences of the edition's modules, in the edition's
  catalogues under `priv/gettext_pro`, beside the core's backend and the core's
  catalogues, which hold the core's alone. Every edition module translates with it, through
  `use ApiaryProWeb` or `use Gettext, backend: ApiaryProWeb.Gettext`; a core component a
  edition page renders translates its sentences with the core's.

  It is built as the core's is, so the words on a page of the edition follow the domain as
  the core's do (the core's `docs/lingo.md`): a domain is a locale, `en@software`, which
  `ApiaryWeb.Lingo` sets for every backend at once; a message a locale's catalogue lacks is
  looked up down the chain of `ApiaryWeb.Gettext.Fallback`; the plural rules are the
  language's (`ApiaryWeb.Gettext.Plural`), and the default locale is the default domain's in
  English. The edition has a catalogue for every locale the core has, and changeset errors
  in the `errors` Gettext domain, which the core's forms find here
  (`c:ApiaryWeb.Edition.gettext_backend/0`).
  """
  use Gettext.Backend,
    otp_app: :apiary,
    priv: "priv/gettext_pro",
    default_locale: ApiaryWeb.Lingo.default_locale(),
    plural_forms: ApiaryWeb.Gettext.Plural

  use ApiaryWeb.Gettext.Fallback
end
