defmodule ApiaryProWeb.ClientLive.SetUpFinishersTest do
  @moduledoc """
  The overview of a client's workspace in set-up names who finishes it to a person who may
  not take the next step's action (`c:Apiary.Edition.set_up_finishers_line/2`). While the
  operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`), a client's admin
  at Machines reads that the operator's owners and admins finish it, and a client's member
  at Work sources reads that the client's and the operator's do.
  """
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Connections, ModelChoices, Repo}
  alias Apiary.Nodes.Node
  alias ApiaryPro.Flags

  @moduletag with_features: Apiary.Features.all()

  setup do
    Flags.put_operator_infrastructure(false)
    operator = operator_fixture()
    client = client_fixture(operator.scope, "Acme")
    admin = client_member_fixture(client, :admin)
    member = client_member_fixture(client, :member)
    %{operator: operator, client: client, admin: admin, member: member}
  end

  defp overview(client), do: ~p"/#{client.organisation}/#{client.workspace}"

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # Name, Work sources, Destinations, Model and Harness done by the client's owner: the
  # next step is Machines.
  defp finish_up_to_machines!(%{owner: %{scope: scope}}) do
    collection = collection_fixture(scope)

    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^collection.adapter_id),
        set: [targets: true]
      )

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-payments-1"}]
      })

    {:ok, _choice} = ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id})
    {:ok, _stack} = Apiary.Stacks.Sources.choose(scope, :qory)
    :ok
  end

  test "a client's admin at Machines reads that the operator's owners and admins finish it",
       %{conn: conn, operator: operator, client: client, admin: admin} do
    finish_up_to_machines!(client)
    Flags.put_operator_infrastructure(true)

    {:ok, lv, _html} = live(log_in_user(conn, admin.user), overview(client))

    assert words(lv, "#overview-set-up-who") ==
             "Owners and admins of #{operator.organisation.name} finish the set-up."

    refute has_element?(lv, "#overview-set-up-continue")
  end

  test "a client's member at Work sources reads that the client's and the operator's finish it",
       %{conn: conn, operator: operator, client: client, member: member} do
    Flags.put_operator_infrastructure(true)

    {:ok, lv, _html} = live(log_in_user(conn, member.user), overview(client))

    assert words(lv, "#overview-set-up-who") ==
             "Owners and admins of Acme and of #{operator.organisation.name} finish the set-up."

    refute has_element?(lv, "#overview-set-up-continue")
  end

  test "with the flag off, a client's member reads the core's line", %{
    conn: conn,
    client: client,
    member: member
  } do
    {:ok, lv, _html} = live(log_in_user(conn, member.user), overview(client))

    assert words(lv, "#overview-set-up-who") == "Owners and admins of Acme finish the set-up."
  end
end
