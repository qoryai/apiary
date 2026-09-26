defmodule Apiary.Accounts.Preferences do
  @moduledoc """
  Preferences holds what a person may choose about how pages look for them: a
  **language**, a **time zone** and a **skin**, stored on the user
  (`Apiary.Accounts.User`). They are the person's in every organisation they belong to;
  what a workspace decides for all of its members, its domain, is not here
  (`Apiary.Lingo.Domain`).

  - A **language** is one the application has catalogues for: the language part of every
    Gettext locale (`en` of `en@software`), and English always, whose source text needs
    no catalogue. `ApiaryWeb.Lingo` builds the locale from it and the workspace's domain.
  - A **time zone** is an IANA name the zone database knows (`tz`, compiled in): times
    are stored in UTC and shown in it. `time_zones/0` is the list a person chooses from,
    each zone with the countries that keep its clock (`time_zone_countries/1`); a link
    name the database also knows (`UTC`, `Europe/Oslo`) is accepted as well.
  - A **skin** says the words and the look over the domain's. Only `standard`, the
    domain's own words, exists: the apiary skin is not built, and nothing offers it.

  A new person reads English in UTC with the standard skin until they change it.
  """

  @default_language "en"
  @default_time_zone "Etc/UTC"
  @default_skin "standard"
  @skins [@default_skin]

  # The zones a person chooses from: the canonical zones of the IANA database's
  # zone1970.tab, one per region of the world with its own clock since 1970, and UTC. The
  # database compiled into `tz` is the one read here, so the list and the validation
  # agree on the release's zone data. A canonical zone serves every country that has kept
  # its clock since 1970 (Europe/Berlin serves Norway too, whose Europe/Oslo is a link to
  # it), so each zone names its countries, from iso3166.tab: every country is findable.
  # The directory is found as `tz` finds it (the latest tzdata in its priv); if `tz` is
  # ever configured with its own `:data_dir` or `:iana_version`, read that here as well.
  @tzdata :tz |> :code.priv_dir() |> Path.join("tzdata20*") |> Path.wildcard() |> Enum.max()
  @zone_tab Path.join(@tzdata, "zone1970.tab")
  @iso_tab Path.join(@tzdata, "iso3166.tab")

  @external_resource @zone_tab
  @external_resource @iso_tab

  rows = fn path ->
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(&String.split(&1, "\t"))
  end

  country_names = Map.new(rows.(@iso_tab), fn [code, name | _] -> {code, name} end)

  @zone_countries Map.new(rows.(@zone_tab), fn [codes, _coordinates, zone | _] ->
                    {zone, codes |> String.split(",") |> Enum.map(&Map.fetch!(country_names, &1))}
                  end)

  @time_zones [@default_time_zone | @zone_countries |> Map.keys() |> Enum.sort()]

  @doc "The language of a person who has not chosen one: English."
  @spec default_language() :: String.t()
  def default_language, do: @default_language

  @doc "The time zone of a person who has not chosen one: UTC."
  @spec default_time_zone() :: String.t()
  def default_time_zone, do: @default_time_zone

  @doc "The skin of a person who has not chosen one: the domain's own words."
  @spec default_skin() :: String.t()
  def default_skin, do: @default_skin

  @doc "The skins a person may have: the standard one, until the apiary skin is built."
  @spec skins() :: [String.t()]
  def skins, do: @skins

  @doc """
  The languages the application has catalogues for, English first: the language part of
  every locale of `ApiaryWeb.Gettext`, and English, whose source text is English.

      iex> Apiary.Accounts.Preferences.languages()
      ["en"]
  """
  @spec languages() :: [String.t()]
  def languages do
    known =
      ApiaryWeb.Gettext
      |> Gettext.known_locales()
      |> Enum.map(&language_of/1)
      |> Enum.sort()

    Enum.uniq([@default_language | known])
  end

  @doc "Whether `language` is one of `languages/0`."
  @spec language?(term) :: boolean
  def language?(language) when is_binary(language), do: language in languages()
  def language?(_language), do: false

  @doc """
  Whether `zone` is a time zone the zone database knows, a canonical name or a link.

      iex> Apiary.Accounts.Preferences.time_zone?("Europe/Berlin")
      true

      iex> Apiary.Accounts.Preferences.time_zone?("Mars/Olympus_Mons")
      false
  """
  @spec time_zone?(term) :: boolean
  def time_zone?(zone) when is_binary(zone) and byte_size(zone) <= 64 do
    match?({:ok, _}, DateTime.now(zone, Tz.TimeZoneDatabase))
  end

  def time_zone?(_zone), do: false

  @doc "The time zones a person chooses from: UTC, then every canonical zone by name."
  @spec time_zones() :: [String.t()]
  def time_zones, do: @time_zones

  @doc """
  The countries a zone of `time_zones/0` keeps the clock of, its own first, by their
  English names in the zone database; none for UTC or a zone outside the list.

      iex> "Norway" in Apiary.Accounts.Preferences.time_zone_countries("Europe/Berlin")
      true
  """
  @spec time_zone_countries(String.t()) :: [String.t()]
  def time_zone_countries(zone), do: Map.get(@zone_countries, zone, [])

  # The language of a locale: `de_AT` of `de_AT@software`. Its plural rules and its
  # catalogue of every sentence are the language's.
  defp language_of(locale), do: locale |> String.split("@", parts: 2) |> hd()
end
