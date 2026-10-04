defmodule Apiary.Secrets.Usage do
  @moduledoc """
  What uses a stored secret: the one question `Apiary.Secrets` asks before it deletes a
  secret or one of its values, and refuses while the answer is not empty.

  Nothing links a secret yet, so the answer is always empty. The piece that links secrets
  to what a run is given answers here, from its own rows, read in the deleting
  transaction after the secret's row is locked: a link written under a lock of the
  secret's row (`FOR KEY SHARE` or stronger) either commits first and is seen, or waits
  for the deletion and then finds no secret to link.

  A use names what uses the secret, for the refusal to say: its `kind` and `id`, a
  `name` to show, and the `value_id` it takes, nil for a secret's one value.
  """

  alias Apiary.Secrets.Secret

  @typedoc "One use of a secret."
  @type use :: %{
          required(:kind) => atom,
          required(:id) => term,
          required(:name) => String.t(),
          required(:value_id) => String.t() | nil
        }

  @doc """
  uses/2 is what uses `secret`, read through `repo`, the deleting transaction's: none,
  until something links a secret.

  A test sets `config :apiary, Apiary.Secrets.Usage, answer: fun`, a function of the
  repository and the secret (`Application.put_env/3`, in a module that is not async), to
  see a refusal before anything links a secret, as a test answers for an edition's level
  above the workspace (`Apiary.Policy.Above`).
  """
  @spec uses(Ecto.Repo.t(), Secret.t()) :: [use]
  def uses(repo, %Secret{} = secret) do
    case Keyword.fetch(Application.get_env(:apiary, __MODULE__, []), :answer) do
      {:ok, fun} when is_function(fun, 2) -> fun.(repo, secret)
      _ -> []
    end
  end
end
