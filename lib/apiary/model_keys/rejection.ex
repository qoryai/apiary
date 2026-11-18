defmodule Apiary.ModelKeys.Rejection do
  @moduledoc """
  A model key that needs a new value because its provider returned 401 to a request that
  carried it: the state `new_key_needed`, whose name no page shows. A gateway's model keys
  report lists such a key in `unauthorized` (`Apiary.ModelKeys.Report`), and the key then
  has one row here, by the value's row id (`secret_values.id`).

    * `rejected_at`: when the provider's 401 arrived, by the gateway's clock, as the report
      has it. The key's page says it: "Anthropic rejected it on 2026-11-18 09:12."
    * `value_set_at`: the key's `value_set_at` when the row was written.

  The row counts while the key's `value_set_at` is still `value_set_at` (`live/1`): any
  new value of the key, from any page, replaces the time, so the state ends, also when the
  new value equals the old one. A claim skips a key while its row counts, and an
  `unauthorized` entry of a later report puts the key back in the state
  (`Apiary.ModelKeys.reject/4`). A rename keeps the row. A key of a provider whose keys are
  sign-ins (`Apiary.ModelKeys.Login`) has the row only when no refresh can fix it
  (`Apiary.ModelKeys.Login.rejectable?/2`), and a refresh that works deletes it.

  The row is of the key's organisation: the database holds `organisation_id` to the
  value's.
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  alias Apiary.Secrets.Value

  @typedoc "The row of a key that needs a new value."
  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type :binary_id
  schema "model_key_rejections" do
    field :secret_value_id, :binary_id, primary_key: true
    belongs_to :organisation, Apiary.Organisations.Organisation

    field :rejected_at, :utc_datetime_usec
    field :value_set_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @doc """
  The condition on a row `:rejection` joined to its key's value `:value`: the row counts,
  the key's `value_set_at` being the one the row was written for (also when both are nil).
  """
  @spec live(Ecto.Query.t()) :: Ecto.Query.t()
  def live(query) do
    from [rejection: r, value: v] in query,
      where: fragment("? IS NOT DISTINCT FROM ?", r.value_set_at, v.value_set_at)
  end

  @doc "The row ids of the values among `secret_ids`' values that have a row that counts."
  @spec live_ids([Ecto.UUID.t()]) :: MapSet.t()
  def live_ids([]), do: MapSet.new()

  def live_ids(secret_ids) when is_list(secret_ids) do
    from(r in __MODULE__,
      as: :rejection,
      join: v in Value,
      as: :value,
      on: v.id == r.secret_value_id,
      where: v.secret_id in ^secret_ids,
      select: v.id
    )
    |> live()
    |> Apiary.Repo.all()
    |> MapSet.new()
  end
end
