defmodule Apiary.Accounts.PreferencesTest do
  use Apiary.DataCase, async: true

  import Apiary.AccountsFixtures

  alias Apiary.Accounts
  alias Apiary.Accounts.{Preferences, Scope}

  doctest Apiary.Accounts.Preferences
  doctest Apiary.Accounts.Scope

  describe "the choices" do
    test "the languages are the catalogues' and English, which needs none" do
      assert hd(Preferences.languages()) == "en"

      for locale <- Gettext.known_locales(ApiaryWeb.Gettext) do
        assert (locale |> String.split("@") |> hd()) in Preferences.languages()
      end
    end

    test "the time zones are UTC first, then canonical zones the database knows" do
      [utc | zones] = Preferences.time_zones()
      assert utc == "Etc/UTC"
      assert zones == Enum.sort(zones)
      assert "Europe/Berlin" in zones
      assert "America/Lima" in zones
      assert Enum.all?(Preferences.time_zones(), &Preferences.time_zone?/1)
    end

    test "a time zone is a name the database knows, a link included" do
      assert Preferences.time_zone?("Etc/UTC")
      assert Preferences.time_zone?("UTC")
      assert Preferences.time_zone?("Asia/Kolkata")

      for zone <- ["", "Europe/Nowhere", "europe/berlin", "+02:00", "CEST", nil, 7, ["UTC"]] do
        refute Preferences.time_zone?(zone), inspect(zone)
      end
    end

    test "the only skin is the standard one, the domain's own words" do
      assert Preferences.skins() == ["standard"]
      assert Preferences.default_skin() == "standard"
    end
  end

  describe "a person's preferences" do
    test "a new person reads English in UTC with the standard skin" do
      user = user_fixture()
      assert %{language: "en", time_zone: "Etc/UTC", skin: "standard"} = user
      assert %{language: "en", time_zone: "Etc/UTC", skin: "standard"} = Repo.reload!(user)
    end

    test "are saved, and the scope reads them" do
      user = user_fixture()

      assert {:ok, user} =
               Accounts.update_user_preferences(user, %{"time_zone" => "Europe/Berlin"})

      assert Repo.reload!(user).time_zone == "Europe/Berlin"
      assert Scope.time_zone(Scope.for_user(user)) == "Europe/Berlin"
      assert Scope.language(Scope.for_user(user)) == "en"
    end

    test "a stored zone the database no longer knows reads UTC" do
      user = %Apiary.Accounts.User{time_zone: "Europe/Dropped_Since"}
      assert Scope.time_zone(Scope.for_user(user)) == "Etc/UTC"
      assert Scope.time_zone(Scope.for_user(%Apiary.Accounts.User{time_zone: nil})) == "Etc/UTC"
      assert Scope.time_zone(%Scope{}) == "Etc/UTC"
      assert Scope.time_zone(Scope.for_user(%Apiary.Accounts.User{time_zone: "UTC"})) == "UTC"
    end

    test "every inhabited country the zone database names is served by a zone of the list" do
      iso =
        Path.wildcard(Path.join(:code.priv_dir(:tz), "tzdata20*/iso3166.tab"))
        |> Enum.max()
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> Enum.map(&(&1 |> String.split("\t") |> Enum.at(1)))

      served = Enum.flat_map(Preferences.time_zones(), &Preferences.time_zone_countries/1)
      # Two uninhabited islands have no clock in the database at all.
      assert iso -- served == ["Bouvet Island", "Heard Island & McDonald Islands"]
      assert "Norway" in Preferences.time_zone_countries("Europe/Berlin")
      assert "Iceland" in Preferences.time_zone_countries("Africa/Abidjan")
      assert Preferences.time_zone_countries("Etc/UTC") == []
    end

    test "refuse a time zone the database does not know" do
      user = user_fixture()

      for zone <- ["Europe/Nowhere", "GMT+25", "europe/berlin", String.duplicate("A", 100)] do
        assert {:error, changeset} = Accounts.update_user_preferences(user, %{time_zone: zone})
        assert Map.has_key?(errors_on(changeset), :time_zone), inspect(zone)
      end

      assert Repo.reload!(user).time_zone == "Etc/UTC"
    end

    test "refuse a language the application has no catalogue for" do
      user = user_fixture()

      assert {:error, changeset} = Accounts.update_user_preferences(user, %{language: "xx"})
      assert %{language: ["is not a language this instance has"]} = errors_on(changeset)

      assert {:error, _changeset} =
               Accounts.update_user_preferences(user, %{language: "en@software"})

      assert {:ok, %{language: "en"}} = Accounts.update_user_preferences(user, %{language: "en"})
    end

    test "refuse a skin that is not built" do
      user = user_fixture()
      assert {:error, changeset} = Accounts.update_user_preferences(user, %{skin: "apiary"})
      assert %{skin: ["is invalid"]} = errors_on(changeset)
    end
  end
end
