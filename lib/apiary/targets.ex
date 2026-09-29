defmodule Apiary.Targets do
  @moduledoc """
  The workspace's targets as the console reads them: the index of them, one target's
  page, and the targets a person pinned.

  A target is what the workspace's runs change, in the system it lives in
  (`Apiary.Runs.Target`), created by the projector when a run first names it; nothing
  here creates one. Every function takes the caller's scope first and reads only the
  scope's workspace.

  **Pins.** A person pins the targets they work in, in a workspace whose runs they read
  (`run.read`), and the sidebar lists the first of them in the order they were pinned. A
  pin is the person's own reading preference, not a change to what the organisation
  holds, so it leaves no audit entry; it goes with its target and with its workspace.

  **The notation.** A target is written as its path, with its system before it only where
  the same path is in more than one system of the workspace (`shared_paths/2`), and on
  the target's own page.
  """

  import Ecto.Query, warn: false

  alias Apiary.Access
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Repo
  alias Apiary.Runs.Target
  alias Apiary.Targets.Pin

  @typedoc "A pinned target as the sidebar lists it."
  @type pinned :: %{id: Ecto.UUID.t(), system: String.t(), path: String.t(), shared: boolean}

  ## One target

  @doc """
  get/3 is the target of the scope's workspace with this system and path, or nil: one
  indexed read.
  """
  @spec get(Scope.t(), String.t(), String.t()) :: Target.t() | nil
  def get(%Scope{} = scope, system, path) when is_binary(system) and is_binary(path) do
    Repo.one(from t in in_scope(scope), where: t.system == ^system and t.path == ^path)
  end

  def get(%Scope{}, _system, _path), do: nil

  @doc "get_by_id/2 is the target of the scope's workspace with this row id, or nil."
  @spec get_by_id(Scope.t(), String.t()) :: Target.t() | nil
  def get_by_id(%Scope{} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one(from t in in_scope(scope), where: t.id == ^id)
      :error -> nil
    end
  end

  @doc """
  shared_paths/2 is which of `paths` are the path of more than one target of the scope's
  workspace, in different systems: the paths the notation writes with their system.
  """
  @spec shared_paths(Scope.t(), [String.t()]) :: MapSet.t(String.t())
  def shared_paths(%Scope{}, []), do: MapSet.new()

  def shared_paths(%Scope{} = scope, paths) when is_list(paths) do
    paths = Enum.uniq(paths)

    from(t in in_scope(scope),
      where: t.path in ^paths,
      group_by: t.path,
      having: count(t.id) > 1,
      select: t.path
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "shared?/2 says whether the target's path is also a path in another system of its workspace."
  @spec shared?(Scope.t(), String.t()) :: boolean
  def shared?(%Scope{} = scope, path) when is_binary(path),
    do: MapSet.member?(shared_paths(scope, [path]), path)

  def shared?(%Scope{}, _path), do: false

  ## Pins

  @doc """
  pin/2 pins `target` for the scope's person, after the ones pinned before. Pinning one
  already pinned changes nothing. `{:error, :not_found}` for a target of another
  workspace, one the person does not read and a scope without a person.
  """
  @spec pin(Scope.t(), Target.t()) :: :ok | {:error, :not_found | :forbidden}
  def pin(%Scope{user: %User{id: user_id}} = scope, %Target{} = target) do
    with :ok <- Access.authorize(scope, :"run.read", target) do
      Repo.insert_all(
        Pin,
        [
          %{
            id: Ecto.UUID.generate(),
            organisation_id: target.organisation_id,
            workspace_id: target.workspace_id,
            user_id: user_id,
            target_id: target.id,
            inserted_at: DateTime.utc_now()
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:organisation_id, :user_id, :target_id]
      )

      :ok
    end
  end

  def pin(%Scope{}, _target), do: {:error, :not_found}

  @doc """
  unpin/2 takes `target` out of the scope's person's pins; unpinning one that is not
  pinned changes nothing. Refused as `pin/2` is.
  """
  @spec unpin(Scope.t(), Target.t()) :: :ok | {:error, :not_found | :forbidden}
  def unpin(%Scope{user: %User{id: user_id}} = scope, %Target{} = target) do
    with :ok <- Access.authorize(scope, :"run.read", target) do
      Repo.delete_all(
        from p in Pin,
          where: p.organisation_id == ^target.organisation_id,
          where: p.user_id == ^user_id and p.target_id == ^target.id
      )

      :ok
    end
  end

  def unpin(%Scope{}, _target), do: {:error, :not_found}

  @doc """
  list_pins/2 is the targets the scope's person pinned in its workspace, in the order they
  were pinned, at most `limit`, each with whether its path is also in another system
  (`shared`). None for a scope without a person or a workspace.
  """
  @spec list_pins(Scope.t(), pos_integer) :: [pinned]
  def list_pins(scope, limit \\ 7)

  def list_pins(
        %Scope{
          user: %User{id: user_id},
          organisation: %Organisation{id: organisation_id},
          workspace: %Workspace{id: workspace_id}
        },
        limit
      ) do
    pins =
      Repo.all(
        from p in Pin,
          join: t in Target,
          on: t.id == p.target_id and t.workspace_id == p.workspace_id,
          where: p.organisation_id == ^organisation_id and p.workspace_id == ^workspace_id,
          where: p.user_id == ^user_id,
          order_by: [asc: p.inserted_at, asc: p.id],
          limit: ^limit,
          select: %{
            id: t.id,
            system: t.system,
            path: t.path,
            shared:
              fragment(
                "EXISTS (SELECT 1 FROM targets o WHERE o.workspace_id = ? AND o.path = ? AND o.id <> ?)",
                t.workspace_id,
                t.path,
                t.id
              )
          }
      )

    pins
  end

  def list_pins(%Scope{}, _limit), do: []

  @doc "pinned_ids/1 is the ids of the targets the scope's person pinned in its workspace."
  @spec pinned_ids(Scope.t()) :: MapSet.t(Ecto.UUID.t())
  def pinned_ids(%Scope{user: %User{id: user_id}} = scope) do
    from(p in pins_in_scope(scope), where: p.user_id == ^user_id, select: p.target_id)
    |> Repo.all()
    |> MapSet.new()
  end

  def pinned_ids(%Scope{}), do: MapSet.new()

  @doc "pinned?/2 says whether the scope's person pinned `target`."
  @spec pinned?(Scope.t(), Target.t()) :: boolean
  def pinned?(%Scope{user: %User{id: user_id}} = scope, %Target{id: id}) do
    Repo.exists?(from p in pins_in_scope(scope), where: p.user_id == ^user_id, where: p.target_id == ^id)
  end

  def pinned?(%Scope{}, _target), do: false

  ## Helpers

  defp in_scope(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{id: workspace_id}
       }) do
    from t in Target,
      where: t.organisation_id == ^organisation_id and t.workspace_id == ^workspace_id
  end

  defp pins_in_scope(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{id: workspace_id}
       }) do
    from p in Pin,
      where: p.organisation_id == ^organisation_id and p.workspace_id == ^workspace_id
  end
end
