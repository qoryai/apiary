defmodule Apiary.Instance do
  @moduledoc """
  The instance's setting for how many invitations an organisation sends, read from the
  environment at boot (`boot!/0`) and fixed for the life of the node.

  `INVITATIONS_PER_DAY`, a whole number from 1, 20 when unset: how many invitations an
  organisation sends in 24 hours (`Apiary.Organisations.invite_member/3`).

  Who may sign up after the instance's first sign-up is the edition's to say
  (`c:Apiary.Edition.sign_up_open?/0`).
  """

  @default_invitations_per_day 20

  @doc """
  invitations_per_day/0 is how many invitations an organisation sends in 24 hours:
  `INVITATIONS_PER_DAY`, #{@default_invitations_per_day} when unset.
  """
  @spec invitations_per_day() :: pos_integer
  def invitations_per_day do
    case Application.fetch_env(:apiary, :invitations_per_day) do
      {:ok, limit} -> limit
      :error -> boot!()
    end
  end

  @doc """
  parse_invitations_per_day/1 reads a value of `INVITATIONS_PER_DAY`: `{:ok, limit}`, a
  whole number from 1, or #{@default_invitations_per_day} for nil or a blank value;
  `{:error, reason}` otherwise.
  """
  @spec parse_invitations_per_day(String.t() | nil) :: {:ok, pos_integer} | {:error, String.t()}
  def parse_invitations_per_day(nil), do: {:ok, @default_invitations_per_day}

  def parse_invitations_per_day(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, @default_invitations_per_day}

      trimmed ->
        case Integer.parse(trimmed) do
          {limit, ""} when limit >= 1 ->
            {:ok, limit}

          _other ->
            {:error, "it is a whole number of invitations from 1, got: #{inspect(trimmed)}"}
        end
    end
  end

  @doc """
  boot!/0 reads `INVITATIONS_PER_DAY` as `config/runtime.exs` left it, checks it and fixes
  it for the life of the node; it returns it. Called at boot; raises on a value
  `parse_invitations_per_day/1` refuses, so the instance does not start.
  """
  @spec boot!() :: pos_integer
  def boot! do
    case parse_invitations_per_day(Application.get_env(:apiary, :invitations_per_day_setting)) do
      {:ok, limit} ->
        Application.put_env(:apiary, :invitations_per_day, limit)
        limit

      {:error, reason} ->
        raise ArgumentError, """
        environment variable INVITATIONS_PER_DAY is not valid: #{reason}.
        Leave it unset for #{@default_invitations_per_day} a day, or set it, for example:
        INVITATIONS_PER_DAY=50
        """
    end
  end
end
