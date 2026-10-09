defmodule ApiaryWeb.Gettext.BackendsTest do
  use ExUnit.Case, async: true

  alias ApiaryWeb.Gettext.Backends

  # A backend with catalogues of its own, as an edition's has: the fixtures of
  # test/support/gettext_fallback, a language's (de) and a domain's (de@software).
  defmodule Edition do
    @moduledoc false
    use Gettext.Backend,
      otp_app: :apiary,
      priv: Path.expand("../../support/gettext_fallback", __DIR__),
      plural_forms: ApiaryWeb.Gettext.Plural

    use ApiaryWeb.Gettext.Fallback
  end

  @backends [ApiaryWeb.Gettext, Edition]

  test "the core's backend comes first, then the edition's when it has one" do
    assert Backends.all() == [ApiaryWeb.Gettext | List.wrap(ApiaryWeb.Edition.gettext_backend())]
  end

  test "a sentence is read from the backend whose catalogues translate it, down the chain" do
    Gettext.with_locale("de@software", fn ->
      assert Backends.dgettext(@backends, "default", "Every target follows it.") ==
               "Jedes Repository folgt ihr."

      assert Backends.dgettext(@backends, "default", "Settings") == "Einstellungen"

      assert Backends.dngettext(@backends, "default", "%{count} target", "%{count} targets", 2) ==
               "2 Repositorys"

      assert Backends.dngettext(@backends, "default", "%{count} member", "%{count} members", 1) ==
               "1 Mitglied"
    end)
  end

  test "the core's catalogues come first where both translate a sentence" do
    Gettext.with_locale("en@software", fn ->
      sentence = "A target appears here once a run names it with its system and target labels."

      translated =
        "A repository appears here once a run names it with its forge and repository labels."

      assert Backends.dgettext(@backends, "default", sentence) == translated
      assert Backends.dgettext(Enum.reverse(@backends), "default", sentence) == translated
    end)
  end

  test "a sentence no catalogue translates is its source text, interpolated" do
    Gettext.with_locale("de@software", fn ->
      assert Backends.dgettext(@backends, "default", "Renamed to %{name}.", name: "x") ==
               "Renamed to x."

      assert Backends.dngettext(@backends, "errors", "%{count} run", "%{count} runs", 3) ==
               "3 runs"
    end)
  end
end
