defmodule ApiaryPro.PolicyTest do
  # The security policy under the edition: a member writes only in the workspaces they were added
  # to, which a write reads again under the workspace's lock. The rest of the policy is
  # `Apiary.PolicyTest`'s.
  use Apiary.DataCase, async: true

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Apiary.OrganisationsFixtures

  alias Apiary.Policy
  alias Apiary.Policy.Error

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  describe "who may" do
    test "a member's write reads their workspace access once, after the workspace's lock", %{
      scope: scope
    } do
      %{scope: member, membership: membership} = member_fixture(scope, :member)
      handler = "workspace-access-reads-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == parent, do: send(parent, {:query, query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      flush_queries()

      assert {:ok, _rule} = Policy.allow(member, nil, %{host: "api.example"})
      queries = flush_queries()

      locked = Enum.find_index(queries, &(&1 =~ ~s("workspaces") and &1 =~ "FOR NO KEY UPDATE"))

      reads =
        for {query, i} <- Enum.with_index(queries),
            query =~ ~s("workspace_access"),
            do: {query, i}

      assert [{read, at}] = reads
      assert read =~ "FOR SHARE"
      assert at > locked

      # Removed from the workspace, the member writes nothing there, as if it did not exist.
      {:ok, _} =
        ApiaryPro.WorkspaceAccess.remove(scope, membership.id, scope.workspace.id)

      assert {:error, %Error{reason: :not_found}} =
               Policy.allow(member, nil, %{host: "other.example"})
    end
  end

  defp flush_queries(acc \\ []) do
    receive do
      {:query, query} -> flush_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
