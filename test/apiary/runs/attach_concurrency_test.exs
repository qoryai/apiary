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
  alias Apiary.Runs.{Attach, Batch, Ingest, Run}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
  end

  # A signed-up organisation whose rows go when the test ends.
  defp committed_scope do
    %{scope: scope, user: user} = sign_up_fixture()

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      Repo.delete_all(
        from o in Apiary.Organisations.Organisation, where: o.id == ^scope.organisation.id
      )

      Repo.delete_all(from u in Apiary.Accounts.User, where: u.id == ^user.id)
      Sandbox.mode(Repo, :manual)
    end)

    scope
  end

  # A run through `gateway`, attached with no instance id kept, as one attached before
  # the instance was kept is: its id and its attach.
  defp attached_without_instance(scope, gateway_key) do
    %{access_key: key} = contract_key_fixture(scope)
    run_id = Ecto.UUID.generate()

    assert {:ok, %{run_key: run_key}} =
             register_run(key, gateway_registration(run_id), instance_id())

    {:ok, body} = Attach.parse(attach_body(run_key))
    assert {:ok, %{repeated: false}} = Attach.attach(gateway_key, run_id, body, %{})
    assert Repo.one!(from r in Run, where: r.node_run_id == ^run_id).gateway_instance_id == nil
    {run_id, body}
  end

  defp at_once(instances, fun) do
    instances
    |> Task.async_stream(fun, timeout: 30_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  test "two instances attach a run with no instance at once: one holds it, the other is refused" do
    scope = committed_scope()
    gateway = gateway_fixture(scope)
    %{access_key: gateway_key} = contract_key_fixture(scope, node: gateway)
    {run_id, body} = attached_without_instance(scope, gateway_key)

    results =
      at_once(
        ["i_first", "i_second"],
        &{&1, Attach.attach(gateway_key, run_id, body, %{instance_id: &1})}
      )

    assert [{winner, {:ok, %{repeated: true}}}] =
             Enum.filter(results, &match?({_instance, {:ok, _answer}}, &1))

    assert [{_loser, {:error, :run_attached}}] =
             Enum.filter(results, &match?({_instance, {:error, _reason}}, &1))

    assert Repo.one!(from r in Run, where: r.node_run_id == ^run_id).gateway_instance_id == winner
  end

  test "two instances send the first batch of a run with no instance at once: one holds it" do
    scope = committed_scope()
    gateway = gateway_fixture(scope)
    %{access_key: gateway_key} = contract_key_fixture(scope, node: gateway)
    {run_id, _body} = attached_without_instance(scope, gateway_key)

    {:ok, batch} =
      [wire_event(run_id, 2, "run.heartbeat", %{"elapsed_seconds" => 30})]
      |> Jason.encode!()
      |> Batch.parse()

    results =
      at_once(["i_first", "i_second"], fn instance ->
        meta = %{contract_version: 1, instance_id: instance}
        {instance, Ingest.ingest(gateway_key, batch, meta)}
      end)

    assert [{winner, {:ok, %{status: 202}}}] =
             Enum.filter(results, &match?({_instance, {:ok, _result}}, &1))

    assert [{_loser, {:error, :wrong_gateway}}] =
             Enum.filter(results, &match?({_instance, {:error, _reason}}, &1))

    run = Repo.one!(from r in Run, where: r.node_run_id == ^run_id)
    assert run.gateway_instance_id == winner
    assert run.event_count == 1
  end

  test "two attaches of one run at once: one attaches it, the other is given the same answer" do
    scope = committed_scope()
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

    run = Repo.one!(from r in Run, where: r.node_run_id == ^run_id)
    assert run.attached_at != nil
    assert run.gateway_id == gateway.id
  end
end
