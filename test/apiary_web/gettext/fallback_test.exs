defmodule ApiaryWeb.Gettext.FallbackTest do
  use ExUnit.Case, async: true

  doctest ApiaryWeb.Gettext.Fallback

  defmodule Backend do
    @moduledoc false
    use Gettext.Backend,
      otp_app: :apiary,
      priv: "test/support/gettext_fallback",
      plural_forms: ApiaryWeb.Gettext.Plural

    use ApiaryWeb.Gettext.Fallback
  end

  defp gettext(locale, msgid, bindings \\ %{}),
    do: Gettext.with_locale(Backend, locale, fn -> Gettext.gettext(Backend, msgid, bindings) end)

  defp ngettext(locale, msgid, plural, n),
    do:
      Gettext.with_locale(Backend, locale, fn -> Gettext.ngettext(Backend, msgid, plural, n) end)

  describe "a domain's catalogue" do
    test "says a sentence in the domain's words when it has it" do
      assert gettext("de@software", "Every target follows it.") == "Jedes Repository folgt ihr."
      assert ngettext("de@software", "%{count} target", "%{count} targets", 2) == "2 Repositorys"
    end

    test "falls back to the language's catalogue for the rest" do
      assert gettext("de@software", "Settings") == "Einstellungen"
      assert ngettext("de@software", "%{count} member", "%{count} members", 1) == "1 Mitglied"
      assert ngettext("de@software", "%{count} member", "%{count} members", 3) == "3 Mitglieder"
    end

    test "falls back through the territory to the language" do
      assert gettext("de_AT@software", "Settings") == "Einstellungen"
    end
  end

  test "the source text is the last resort, interpolated" do
    assert gettext("de@software", "Renamed to %{name}.", name: "x") == "Renamed to x."
    assert ngettext("de", "%{count} run", "%{count} runs", 2) == "2 runs"
  end
end
