defmodule Apiary.Organisations.Slug do
  @moduledoc """
  Slug is the name of an organisation or a workspace in a URL: `/acme/platform/runs`. An
  organisation's slug is unique on the instance, a workspace's within its organisation.

  A slug is 1 to 40 characters of lowercase `a`–`z`, `0`–`9` and hyphens, and starts
  and ends with a letter or a digit. An organisation's is made from the name when it is
  created (`from_name/1`) and again on each rename. A sign-up and a rename refuse a name
  whose slug is taken (`Apiary.Organisations.sign_up_user/3`,
  `Apiary.Organisations.change_organisation/2`); an edition's way of creating one that
  does not pass `taken: :refuse` to `Apiary.Organisations.build_organisation/2` numbers
  it (`pick/3`). A workspace's is made from the name at
  creation and on each rename, and a name whose slug is taken is refused
  (`Apiary.Organisations.change_workspace/2`). A name with no letter or digit from A to
  Z or 0 to 9 gives no slug, and every one of these ways refuses it (`no_letters/0`). A
  slug is never one of the names the router reserves (`ApiaryWeb.ReservedSlugs`).

  The migration that gave the existing rows their slugs made them the same way, with a
  copy of these rules as they were then.
  """

  import Ecto.Changeset

  use Gettext, backend: ApiaryWeb.Gettext

  @max_length 40
  @format ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/

  @doc """
  valid?/1 says whether `slug` keeps the rules: the characters and the length. It does not
  ask whether a slug is reserved or taken.

      iex> Apiary.Organisations.Slug.valid?("acme-2")
      true

      iex> Apiary.Organisations.Slug.valid?("favicon.ico")
      false
  """
  @spec valid?(term) :: boolean
  def valid?(slug) when is_binary(slug),
    do: String.length(slug) <= @max_length and Regex.match?(@format, slug)

  def valid?(_slug), do: false

  @doc "max_length/0 is the longest a slug may be."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  from_name/1 makes a slug from a name: accents dropped, lowercased, every run of other
  characters one hyphen, cut to `max_length/0`. A name with no letter or digit from A to Z
  or 0 to 9 left gives nil: it has no address, and the caller refuses it
  (`no_letters/0`).

      iex> Apiary.Organisations.Slug.from_name("Café Société, Platform")
      "cafe-societe-platform"

      iex> Apiary.Organisations.Slug.from_name("—")
      nil
  """
  @spec from_name(String.t() | nil) :: String.t() | nil
  def from_name(name) when is_binary(name) do
    slug =
      name
      |> :unicode.characters_to_nfd_binary()
      |> String.replace(~r/[^\x00-\x7F]/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> trim()

    if slug == "", do: nil, else: slug
  end

  def from_name(_name), do: nil

  @doc """
  from_name/2 is `from_name/1`, or `fallback` for a name that gives no slug. No way of
  naming an organisation or a workspace uses it: those refuse such a name
  (`no_letters/0`). It is kept for an edition's demo data and tests.
  """
  @spec from_name(String.t() | nil, String.t()) :: String.t()
  def from_name(name, fallback), do: from_name(name) || fallback

  @doc "no_letters/0 is the error of a name that gives no slug (`from_name/1`), on the name."
  @spec no_letters() :: String.t()
  def no_letters,
    do:
      dgettext_noop(
        "errors",
        "Choose a name with at least one letter or digit from A to Z or 0 to 9. The address is made from those characters."
      )

  @doc """
  pick/3 is the first of `base`, `base-2`, `base-3`, … that is not in `reserved` and for
  which `taken?` answers false, each cut to fit `max_length/0`.
  """
  @spec pick(String.t(), [String.t()], (String.t() -> boolean)) :: String.t()
  def pick(base, reserved, taken?) when is_function(taken?, 1) do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&candidate(base, &1))
    |> Enum.find(&(&1 not in reserved and not taken?.(&1)))
  end

  defp candidate(base, 1), do: base

  defp candidate(base, n) do
    suffix = "-#{n}"
    trim(String.slice(base, 0, @max_length - String.length(suffix))) <> suffix
  end

  defp trim(slug), do: slug |> String.slice(0, @max_length) |> String.trim("-")

  @doc """
  validate/2 checks the slug of a changeset: present, short enough, of the allowed
  characters, and not one of `reserved`.
  """
  @spec validate(Ecto.Changeset.t(), [String.t()]) :: Ecto.Changeset.t()
  def validate(changeset, reserved) do
    changeset
    |> validate_required([:slug])
    |> validate_length(:slug, max: @max_length)
    |> validate_format(:slug, @format,
      message:
        dgettext_noop(
          "errors",
          "may hold lowercase letters, digits and hyphens, and starts and ends with a letter or a digit"
        )
    )
    |> validate_exclusion(:slug, reserved,
      message: dgettext_noop("errors", "is kept by Qory Apiary")
    )
  end
end
