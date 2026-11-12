defmodule ApiaryProWeb.GettextTest do
  @moduledoc """
  The edition's sentences have a separate backend (`ApiaryProWeb.Gettext`): every module
  of the edition translates with it, and its catalogues, `priv/gettext_pro`, list the
  edition's files alone, as the core's list the core's alone. The backend is built as the
  core's is, so a page of the edition follows the domain as a core page does, and a
  changeset error of the edition's on a core form is found in the edition's catalogues.
  """
  use ExUnit.Case, async: true

  use Gettext, backend: ApiaryProWeb.Gettext

  alias ApiaryWeb.Gettext.Backends

  @root Path.expand("../..", __DIR__)

  # The edition's code, and its catalogues.
  @pro_code ["lib/apiary_pro", "lib/apiary_pro_web", "lib/apiary_pro_web.ex"]
  @pro_priv Path.join(@root, "priv/gettext_pro")

  # The core's backend, not one of its modules such as its fallback chain, which the edition's
  # backend is built with.
  @core_backend ~r/\bApiaryWeb\.Gettext\b(?!\.[A-Z])/

  defp pro?(file),
    do: Enum.any?(@pro_code, &(file == &1 or String.starts_with?(file, &1 <> "/")))

  defp pro_code_files do
    for path <- @pro_code,
        file <-
          if(String.ends_with?(path, ".ex"),
            do: [Path.join(@root, path)],
            else: Path.wildcard(Path.join([@root, path, "**", "*.{ex,exs,heex}"]))
          ),
        do: Path.relative_to(file, @root)
  end

  defp references(path) do
    for message <- Expo.PO.parse_file!(path).messages,
        reference <- List.flatten(message.references),
        do: with({file, _line} <- reference, do: file)
  end

  describe "the edition's backend" do
    test "has the core's default locale, the default domain's in English" do
      assert ApiaryProWeb.Gettext.__gettext__(:default_locale) ==
               ApiaryWeb.Lingo.default_locale()
    end

    test "follows the locale set for every backend, and its plural rules" do
      Gettext.with_locale("en@software", fn ->
        assert ngettext("%{number} client", "%{number} clients", 1, number: "1") == "1 client"
        assert ngettext("%{number} client", "%{number} clients", 2, number: "2") == "2 clients"
      end)
    end

    test "is the edition's, after the core's, for a sentence the core does not know is the edition's" do
      assert Backends.all() == [ApiaryWeb.Gettext, ApiaryProWeb.Gettext]

      assert ApiaryWeb.CoreComponents.translate_error(
               {"cannot be an operator: it is a client of one", []}
             ) == "cannot be an operator: it is a client of one"
    end
  end

  describe "the boundary" do
    test "the edition's code is found, and every file of it translates with the edition's backend" do
      files = pro_code_files()

      assert "lib/apiary_pro_web.ex" in files
      assert "lib/apiary_pro_web/gettext.ex" in files
      assert "lib/apiary_pro/tenants.ex" in files

      naming =
        for file <- files,
            File.read!(Path.join(@root, file)) =~ @core_backend,
            do: file

      assert naming == [],
             "these files of the edition's name the core's Gettext backend: #{Enum.join(naming, ", ")}"
    end

    test "the edition's catalogues name the edition's files alone" do
      catalogues = Path.wildcard(Path.join(@pro_priv, "**/*.{pot,po}"))
      assert Path.join(@pro_priv, "default.pot") in catalogues

      for catalogue <- catalogues do
        files = references(catalogue)
        assert files != [], "#{catalogue} names no file"

        others = files |> Enum.reject(&pro?/1) |> Enum.uniq()

        assert others == [],
               "#{catalogue} names files outside the edition's: #{Enum.join(others, ", ")}"
      end
    end
  end
end
