defmodule Mix.Tasks.Apiary.Demo.CodeHost do
  @moduledoc false

  # The demo's repositories as targets of a workspace, made as an adapter's collections
  # make them, for `mix apiary.demo` and `mix apiary.demo.history`: the instance's adapter
  # Example code host, made where the instance has none; the organisation's connection to
  # it, made where it has none; and per repository a collection of that adapter, assigned
  # to the workspace, whose target has that collection's ref and the repository's
  # address. Rows are written straight into the tables, as a listing and an
  # assignment would leave them, without the adapter's wire.

  import Ecto.Query

  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Nodes.Node
  alias Apiary.Repo
  alias Apiary.Runs.Target

  @name "Example code host"

  @doc false
  # The workspace's target of the repository at `system` and `path`: the target of the
  # adapter's live collection there, by adapter and collection ref; nil where the
  # instance has no such adapter or the workspace no such collection or target.
  @spec target(Ecto.UUID.t(), String.t(), String.t()) :: Target.t() | nil
  def target(workspace_id, system, path) do
    with %Node{id: adapter_id} <- adapter(),
         ref when is_binary(ref) <-
           Repo.one(
             from c in Collection,
               where: c.adapter_id == ^adapter_id and c.workspace_id == ^workspace_id,
               where: c.target_system == ^system and c.target_path == ^path,
               where: is_nil(c.ended_at),
               order_by: [c.inserted_at, c.id],
               limit: 1,
               select: c.target_collection_external_ref
           ) do
      Repo.one(
        Target.by_key(workspace_id, %{adapter_id: adapter_id, collection_external_ref: ref})
      )
    else
      _none -> nil
    end
  end

  @doc false
  # Makes the repositories at `addresses`, `%{system: system, path: path}` each, targets
  # of the scope's workspace, through collections of the adapter (the moduledoc). A
  # collection or target made before is kept.
  @spec targets!(Scope.t(), [%{system: String.t(), path: String.t()}]) :: :ok
  def targets!(%Scope{organisation: organisation, workspace: workspace} = scope, addresses) do
    adapter = adapter() || insert_adapter!()
    connection = connection!(scope, adapter)
    now = DateTime.utc_now(:second)

    collections =
      for %{system: system, path: path} <- Enum.uniq_by(addresses, &{&1.system, &1.path}) do
        # A live collection's ref is unique per adapter on the instance, so it has the
        # workspace's id; its target has the same ref.
        external_ref = "#{workspace.public_id}/#{system}/#{path}"

        Repo.one(
          from c in Collection,
            where: c.adapter_id == ^adapter.id and c.external_ref == ^external_ref,
            where: is_nil(c.ended_at)
        ) ||
          Repo.insert!(%Collection{
            public_id: Apiary.PublicId.generate(Collection.prefix()),
            organisation_id: organisation.id,
            adapter_id: adapter.id,
            connection_id: connection.id,
            workspace_id: workspace.id,
            external_ref: external_ref,
            url: "https://#{system}/#{path}",
            title: path,
            target_collection_external_ref: external_ref,
            target_system: system,
            target_path: path,
            last_listed_at: now
          })
      end

    Target.insert_new(organisation.id, workspace.id, Enum.map(collections, &Collection.target/1))
  end

  defp adapter do
    Repo.one(
      from n in Node,
        where: n.kind == :adapter and n.name == @name,
        where: is_nil(n.organisation_id) and is_nil(n.workspace_id) and is_nil(n.deleted_at),
        order_by: n.inserted_at,
        limit: 1
    )
  end

  defp insert_adapter! do
    %Node{kind: :adapter, gateway_choice: :direct}
    |> Node.adapter_changeset(%{name: @name})
    |> Repo.insert!()
  end

  # The organisation's live connection to `adapter`, else a connected one made now, by the
  # scope's person.
  defp connection!(%Scope{organisation: organisation, user: user}, %Node{id: adapter_id}) do
    Repo.one(
      from k in Connection,
        where: k.organisation_id == ^organisation.id and k.adapter_id == ^adapter_id,
        where: is_nil(k.ended_at)
    ) ||
      Repo.insert!(%Connection{
        public_id: Apiary.PublicId.generate(Connection.prefix()),
        organisation_id: organisation.id,
        adapter_id: adapter_id,
        created_by_id: user.id,
        state: :connected,
        pass_nonce: :crypto.strong_rand_bytes(16),
        connected_at: DateTime.utc_now()
      })
  end
end
