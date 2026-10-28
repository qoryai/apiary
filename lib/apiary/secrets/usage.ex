defmodule Apiary.Secrets.Usage do
  @moduledoc """
  What uses a stored secret: the one question `Apiary.Secrets` asks before it deletes a
  secret or one of its values, or gives a value another value id, and refuses while the
  answer is not empty. It is asked in the changing transaction, after the secret's row is
  locked.

  A model provider (`Apiary.Connections`) uses the secret it links, of the organisation or
  of a workspace, whose values are its keys, and by its value id the value that is its
  default key: a use of kind `:model_provider`. A model choice that chose one of those keys uses that value: a
  use of kind `:model_choice`. Nothing else uses a secret; a test adds further uses
  (`uses/2`).

  A use names what uses the secret, for the refusal to say: its `kind` and `id`, a
  `name` to show, and the `value_id` it takes, nil for a secret's one value.
  """

  import Ecto.Query

  alias Apiary.Connections.Connection
  alias Apiary.{ModelChoices, Repo}
  alias Apiary.Secrets.Secret

  @typedoc "One use of a secret."
  @type use :: %{
          required(:kind) => atom,
          required(:id) => term,
          required(:name) => String.t(),
          required(:value_id) => String.t() | nil
        }

  @doc """
  uses/2 is what uses `secret`, read through `repo`, the changing transaction's: the
  model providers that link it, by their public id and name, each with its default key's
  value id, in the order of their names; then the model choices that chose one of its
  values as their key, by that value id.

  A test sets `config :apiary, Apiary.Secrets.Usage, answer: fun`, a function of the
  repository and the secret (`Application.put_env/3`, in a module that is not async), whose
  uses come after the providers', to see a refusal, as a test answers for an edition's
  level above the workspace (`Apiary.Policy.Above`).
  """
  @spec uses(Ecto.Repo.t(), Secret.t()) :: [use]
  def uses(repo, %Secret{} = secret) do
    providers(repo, secret) ++ choices(secret) ++ answered(repo, secret)
  end

  @doc """
  provider_keys?/1 says whether a model provider links the secret with the row id
  `secret_id`, read without a lock.
  """
  @spec provider_keys?(Ecto.UUID.t()) :: boolean
  def provider_keys?(secret_id),
    do: Repo.exists?(from c in Connection, where: c.secret_id == ^secret_id)

  defp providers(repo, %Secret{id: id, organisation_id: organisation_id}) do
    repo.all(
      from c in Connection,
        where: c.organisation_id == ^organisation_id and c.secret_id == ^id,
        order_by: [asc: fragment("lower(?)", c.name), asc: c.id],
        select: %{
          kind: :model_provider,
          id: c.public_id,
          name: c.name,
          value_id: c.default_value_id
        }
    )
  end

  # With the `factory` feature: a model choice
  # (`Apiary.ModelChoices`) that chose a key of a provider's secret uses that key, by its
  # value id, a use of kind `:model_choice` named as a refusal names its place. Read in
  # the caller's transaction, which holds the provider's row.
  defp choices(%Secret{id: id}) do
    for place <- ModelChoices.key_places(id) do
      %{
        kind: :model_choice,
        id: nil,
        name: ModelChoices.place_words(place),
        value_id: place.value_id
      }
    end
  end

  defp answered(repo, secret) do
    case Keyword.fetch(Application.get_env(:apiary, __MODULE__, []), :answer) do
      {:ok, fun} when is_function(fun, 2) -> fun.(repo, secret)
      _ -> []
    end
  end
end
