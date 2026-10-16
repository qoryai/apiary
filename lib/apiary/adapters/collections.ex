defmodule Apiary.Adapters.Collections do
  # The collections an organisation's connection to an adapter reaches, as the adapter's
  # listing names them, each assigned to a workspace or to none; assigning them to a
  # workspace (`collection.assign`, owners and admins); and the topic an open page
  # follows the listing on. A collection is an engine word (docs/lingo.md).
  #
  # Not built: each function answers `{:error, :not_built}`.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.Connection
  alias Apiary.Organisations.Workspace

  @typedoc "A collection a connection reaches, with its workspace and when it was added."
  @type row :: %{
          id: Ecto.UUID.t(),
          name: String.t(),
          workspace: Workspace.t() | nil,
          added_at: DateTime.t()
        }

  @doc false
  # The collections `connection` reaches, by name, to a person who may read the instance's
  # adapters in its organisation (`adapter.read`). Not built: `{:error, :not_built}`.
  @spec list_collections(Scope.t(), Connection.t()) :: [row] | {:error, :not_built}
  def list_collections(%Scope{}, %Connection{}), do: {:error, :not_built}

  @doc false
  # How many of the collections `connection` reaches are assigned to no workspace. Not
  # built: `{:error, :not_built}`.
  @spec count_unassigned(Scope.t(), Connection.t()) :: non_neg_integer | {:error, :not_built}
  def count_unassigned(%Scope{}, %Connection{}), do: {:error, :not_built}

  @doc false
  # Assigns the collections of `connection` whose ids are `ids` to `workspace`
  # (`collection.assign`): `{:ok, count}`, how many moved. Not built: `{:error, :not_built}`.
  @spec assign_collections(Scope.t(), Connection.t(), [Ecto.UUID.t()], Workspace.t()) ::
          {:ok, non_neg_integer} | {:error, :not_built | Access.reason()}
  def assign_collections(%Scope{}, %Connection{}, ids, %Workspace{}) when is_list(ids),
    do: {:error, :not_built}

  @doc false
  # Subscribes the caller to `connection`'s listing, a message as each part of it is
  # accepted. Not built: `{:error, :not_built}`.
  @spec subscribe(Scope.t(), Connection.t()) :: :ok | {:error, :not_built | Access.reason()}
  def subscribe(%Scope{}, %Connection{}), do: {:error, :not_built}
end
