defmodule Apiary.Connections.ProviderModel do
  @moduledoc """
  A model on a model provider's list (`Apiary.Connections.Connection`): `model_id`, the id
  exactly as the provider's API takes it, 1 to 200 printable ASCII characters with no
  space, starting with a letter or a digit; `title`, 1 to 128 characters; `effort`, the
  effort values the model accepts, 1 to 16, each once, or nil for a model with none;
  `position`, its place in the list; and `is_default`, set on at most one model of a
  provider. Changed only through `Apiary.Connections`.
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Changeset

  @typedoc "A model on a provider's list."
  @type t :: %__MODULE__{}

  @model_id ~r/\A[A-Za-z0-9][!-~]{0,199}\z/
  @effort_value ~r/\A[a-z][a-z0-9-]{0,31}\z/
  @effort_max 16
  @title_max 128
  @models_max 200

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "provider_models" do
    field :model_id, :string
    field :title, :string
    field :effort, {:array, :string}
    field :position, :integer
    field :is_default, :boolean, default: false

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :connection, Apiary.Connections.Connection

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The most models a provider has."
  @spec models_max() :: pos_integer
  def models_max, do: @models_max

  @doc "The most effort values a model has."
  @spec effort_max() :: pos_integer
  def effort_max, do: @effort_max

  @doc """
  changeset/2 is the changeset of a model's `model_id`, `title` and `effort`. A blank
  title is the model id, cut to 128 characters; an empty list of effort values is nil.
  """
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = model, attrs) do
    model
    |> cast(attrs, [:model_id, :title, :effort], empty_values: [nil])
    |> update_change(:title, &trim/1)
    |> update_change(:effort, &empty_to_nil/1)
    |> validate_required([:model_id])
    |> validate_format(:model_id, @model_id,
      message:
        dgettext_noop(
          "errors",
          "Use 1 to 200 ASCII letters, digits and punctuation with no space, starting with a letter or a digit."
        )
    )
    |> default_title()
    |> validate_length(:title, min: 1, max: @title_max, count: :codepoints)
    |> Apiary.Names.validate_characters(:title)
    |> validate_effort()
  end

  @doc """
  taken/2 is `changeset` with the error that its provider already lists the model
  `model_id`.
  """
  @spec taken(Ecto.Changeset.t(), String.t()) :: Ecto.Changeset.t()
  def taken(%Ecto.Changeset{} = changeset, model_id),
    do:
      add_error(
        changeset,
        :model_id,
        dgettext_noop(
          "errors",
          "Edit the model already listed, or enter another ID. This provider already has %{model}."
        ),
        model: model_id
      )

  defp default_title(changeset) do
    case {get_field(changeset, :title), get_field(changeset, :model_id)} do
      {title, model_id} when title in [nil, ""] and is_binary(model_id) ->
        put_change(changeset, :title, String.slice(model_id, 0, @title_max))

      _given ->
        changeset
    end
  end

  defp validate_effort(changeset) do
    validate_change(changeset, :effort, fn :effort, values ->
      cond do
        length(values) > @effort_max or length(Enum.uniq(values)) != length(values) ->
          [effort: {effort_message(), count: @effort_max}]

        Enum.any?(values, &(not (is_binary(&1) and Regex.match?(@effort_value, &1)))) ->
          [
            effort:
              dgettext_noop(
                "errors",
                "Use 1 to 32 lower-case letters, digits and hyphens, starting with a letter, such as high."
              )
          ]

        true ->
          []
      end
    end)
  end

  defp effort_message,
    do: dgettext_noop("errors", "List at most %{count} effort values, each once.")

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp empty_to_nil([]), do: nil
  defp empty_to_nil(values), do: values
end
