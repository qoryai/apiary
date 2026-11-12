defmodule ApiaryProWeb.LingoCatalogueTest do
  @moduledoc """
  The edition's catalogues, `priv/gettext_pro`, held to the rules the core's are
  (`ApiaryWeb.LingoCatalogueCase`): a sentence of the edition's with an engine word is translated
  in every domain, a domain translates nothing else, and nothing is fuzzy. The edition has a
  catalogue for every locale the core has, so a domain that says the core's sentences in
  its words says the edition's too.
  """
  use ApiaryWeb.LingoCatalogueCase,
    async: true,
    priv: Path.expand("../../priv/gettext_pro", __DIR__)

  # The core's catalogues, in the core's application.
  @core Application.app_dir(:apiary, "priv/gettext")

  test "the edition has a catalogue for every locale of the core's, and for none other" do
    assert locales(@priv) == locales(@core)

    assert Enum.sort(Gettext.known_locales(ApiaryProWeb.Gettext)) ==
             Enum.sort(Gettext.known_locales(ApiaryWeb.Gettext))
  end
end
