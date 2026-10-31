defmodule Apiary.Artifacts.Filename do
  # Filename checks the name a writer sets for a file of an artifact's version. A filename
  # is shown on pages and sent back to runs, and never becomes a path
  # (`Apiary.Artifacts.Store.Volume` makes paths from digests alone).
  #
  # A filename is UTF-8, 1 to 255 bytes, a base name: no `/` and no `\`, neither `.` nor
  # `..`, and no control character (NUL among them), format character, or line or
  # paragraph separator, so a name cannot hide its end or reverse its text on a page.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  @max_bytes 255
  @refused ~r/[\p{Cc}\p{Cf}\x{2028}\x{2029}\/\\]/u

  # valid?/1 is whether `name` is a filename an artifact's file may have.
  @doc false
  @spec valid?(term) :: boolean
  def valid?(name) when is_binary(name) do
    byte_size(name) in 1..@max_bytes and name not in [".", ".."] and String.valid?(name) and
      not Regex.match?(@refused, name)
  end

  def valid?(_name), do: false

  # max_bytes/0 is the most bytes a filename has.
  @doc false
  @spec max_bytes() :: pos_integer
  def max_bytes, do: @max_bytes
end
