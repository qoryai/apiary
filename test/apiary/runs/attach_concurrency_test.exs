defmodule Apiary.Runs.AttachConcurrencyTest do
  # Real transactions on real connections: the sandbox would run the two attaches one
  # after the other on one connection and prove nothing. What the test commits goes with
  # its organisation and its user when it ends.
  use ExUnit.Case, async: false

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.Repo
  alias Apiary.Runs.{Attach, Run}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
  end

  test "two attaches of one run at once: one attaches it, the other is given the same answer" do
    %{scope: scope, user: user} = sign_up_fixture()

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      Repo.delete_all(
        from o in Apiary.Organisations.Organisation, where: o.id == ^scope.organisation.id
      )

      Repo.delete_all(from u in Apiary.Accounts.User, where: u.id == ^user.id)
      Sandbox.mode(Repo, :manual)
    end)

    gateway = gateway_fixture(scope)
    %{access_key: first} = contract_key_fixture(scope, node: gateway)
    %{access_key: second} = contract_key_fixture(scope, node: gateway)
    %{access_key: key} = contract_key_fixture(scope)

    run_id = Ecto.UUID.generate()

    assert {:ok, %{run_key: run_key}} =
             register_run(key, gateway_registration(run_id), instance_id())

    {:ok, body} = Attach.parse(attach_body(run_key))

    results =
      [first, second]
      |> Task.async_stream(&Attach.attach(&1, run_id, body, %{}), timeout: 30_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, one}, {:ok, other}] = results
    assert Enum.sort([one.repeated, other.repeated]) == [false, true]
    assert one.settings == other.settings
    assert one.digest == other.digest

    run = Repo.one!(from r in Run, where: r.run_id == ^run_id)
    assert run.attached_at != nil
    assert run.gateway_id == gateway.id
  end
end
