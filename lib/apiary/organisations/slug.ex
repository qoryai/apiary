defmodule Apiary.Organisations.Slug do
  @moduledoc """
  Slug is the name of an organisation or a workspace in a URL: `/acme/platform/runs`
  (decision 0073). An organisation's slug is unique on the instance, a workspace's within
  its organisation.

  A slug is 1 to 40 characters of lowercase `a`–`z`, `0`–`9` and hyphens, and starts
  and ends with a letter or a digit. It is made from the name when the organisation or
  the workspace is created (`from_name/2`), made unique with a number (`pick/3`), and
  kept when the name changes: renaming a slug is not decided yet. It is never one of the
  names the router reserves (`ApiaryWeb.ReservedSlugs`).

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
  from_name/2 makes a slug from a name: accents dropped, lowercased, every run of other
  characters one hyphen, cut to `max_length/0`. A name with nothing left gives `fallback`.

      iex> Apiary.Organisations.Slug.from_name("Café Société, Platform", "workspace")
      "cafe-societe-platform"

      iex> Apiary.Organisations.Slug.from_name("—", "workspace")
      "workspace"
  """
  @spec from_name(String.t(), String.t()) :: String.t()
  def from_name(name, fallback) when is_binary(name) do
    slug =
      name
      |> :unicode.characters_to_nfd_binary()
      |> String.replace(~r/[^\x00-\x7F]/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> trim()

    if slug == "", do: fallback, else: slug
  end

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
      message: dgettext_noop("errors", "is reserved for a page of Qory Apiary")
    )
  end
end
