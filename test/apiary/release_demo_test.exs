defmodule Apiary.ReleaseDemoTest do
  @moduledoc """
  The release command that fills a test instance with the demo, `Apiary.Release.demo/1`,
  run as `bin/apiary eval` runs it: with the endpoint's address removed, as no endpoint
  runs there, so each link of the demo takes the configured address, and with the job
  queue in testing mode, which inserts the jobs the demo queues and runs none.
  """
  # Not async: the command acts on the instance's organisation, which every test shares,
  # and the history writes from processes of its own, on the shared sandbox.
  use Apiary.DataCase, async: false

  # The release whose fetch fails on purpose says so in the log.
  @moduletag :capture_log

  import ExUnit.CaptureIO
  import Apiary.OrganisationsFixtures

  alias Apiary.{Accounts, Release}
  alias Apiary.AccessKeys.EnrolmentCode
  alias Apiary.Accounts.User
  alias Apiary.Integrations.Release, as: IntegrationRelease
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias Apiary.Runs.Run

  # The password `mix apiary.demo.console` gives Dana, public in the repository.
  @known "demo-console-acme"
  @operator "ops@example.com"
  @small [runs: 140, days: 12, concurrency: 1]

  setup do
    # As on a new database: the suite's instance organisation hidden, and every
    # organisation of this test's sandbox marked for deletion.
    Apiary.EditionKit.hide_instance_organisation()
    now = DateTime.utc_now()

    Repo.update_all(Organisation,
      set: [
        deletion_marked_at: now,
        purge_after: DateTime.add(now, 30, :day),
        purge_trigger: "grace_period"
      ]
    )

    # No endpoint runs under `bin/apiary eval`: its address is not there.
    key = {Phoenix.Endpoint, ApiaryWeb.Endpoint}
    endpoint = :persistent_term.get(key)
    :persistent_term.erase(key)
    on_exit(fn -> :persistent_term.put(key, endpoint) end)

    :ok
  end

  defp demo do
    send(self(), {:result, nil})

    {stdout, stderr} =
      with_io(:stderr, fn ->
        capture_io(fn -> send(self(), {:result, Release.demo(@small)}) end)
      end)

    assert_received {:result, nil}
    assert_received {:result, result}
    {result, stdout, stderr}
  end

  defp lines(output), do: String.split(output, "\n", trim: true)

  defp configured_url,
    do: Apiary.Setup.configured_url(Application.get_env(:apiary, ApiaryWeb.Endpoint, []))

  defp set_up_acme,
    do: sign_up_fixture(%{email: @operator, organisation_name: "Acme"})

  defp count(query), do: Repo.aggregate(query, :count)

  @tag :feature_sets
  test "fills Acme set up by its operator: Main's runs, Dana an owner, the fill finished" do
    %{organisation: acme, workspace: main} = set_up_acme()

    # An operator who set the instance up from a shell has not confirmed the address yet.
    Repo.update_all(from(u in User, where: u.email == ^@operator), set: [confirmed_at: nil])

    {result, stdout, stderr} = demo()

    assert {:ok, summary} = result
    assert lines(stderr) == ["Loading the demo into acme/main."]

    url = configured_url()

    last =
      if Apiary.Features.on?(:factory),
        do: "Open the Backlog and take a ticket in: #{url}/acme/main/backlog",
        else: "Open the runs: #{url}/acme/main/runs"

    assert lines(stdout) == [
             "acme/main has #{summary.runs} runs in #{summary.repositories} repositories; " <>
               "acme has #{summary.people} people and #{summary.invitations} pending " <>
               "invitations.",
             "To sign in as dana@example.com (instance admin), print a link that sets the " <>
               "password: bin/apiary eval 'Apiary.Release.password_link(\"dana@example.com\")'",
             last
           ]

    # The history's 140 runs, the 5 recordings and the run alive now.
    assert summary.runs == count(from r in Run, where: r.workspace_id == ^main.id)
    assert summary.runs >= 146
    # The operator and the 11 people of the demo.
    assert summary.people == 12
    assert summary.invitations == 2

    dana = Accounts.get_user_by_email("dana@example.com")

    assert Repo.get_by!(Membership, organisation_id: acme.id, user_id: dana.id).level ==
             :owner

    assert Apiary.Edition.instance_organisation_id() == acme.id

    # The fill's last step, the mark of a fill that finished.
    assert Repo.exists?(
             from c in EnrolmentCode,
               where: c.organisation_id == ^acme.id and c.label_hint == "build-01-next",
               where: not is_nil(c.cancelled_at)
           )

    # Nobody signs in with the known password; each account the demo made has a password
    # nobody was told.
    made =
      Repo.all(
        from u in User,
          join: m in Membership,
          on: m.user_id == u.id,
          where: m.organisation_id == ^acme.id and u.email != ^@operator
      )

    assert length(made) == 11

    for user <- made do
      assert user.hashed_password
      refute Accounts.get_user_by_email_and_password(user.email, @known)
    end

    # The job each release request queues is inserted; the command fetched the release.
    # The count reads Acme's jobs only: other test files commit jobs outside the sandbox.
    if Apiary.Features.on?(:secrets) do
      assert count(
               from j in Oban.Job,
                 where: j.worker == "Apiary.Integrations.FetchJob",
                 where: fragment("?->>'organisation_id'", j.args) == ^acme.id
             ) == 3

      refute Repo.exists?(from r in IntegrationRelease, where: r.state == "pending")
    end

    # Run again, the command refuses the workspace it filled and makes nothing more.
    runs = count(Run)
    assert {{:error, :filled}, stdout, ""} = demo()

    assert stdout ==
             "Run this command on a new instance set up with the organisation name Acme. " <>
               "acme/main already has runs or nodes.\n"

    assert count(Run) == runs
  end

  test "refuses an instance nobody has set up, and makes nothing" do
    assert {{:error, :not_set_up}, stdout, ""} = demo()

    assert stdout ==
             "Set up the instance with the organisation name Acme, then run this command " <>
               "again. The instance is not set up yet.\n"

    refute Repo.exists?(from o in Organisation, where: is_nil(o.deletion_marked_at))
    refute Repo.exists?(Run)
  end

  test "refuses an instance whose organisation is not Acme, and makes nothing" do
    %{organisation: other} =
      sign_up_fixture(%{email: @operator, organisation_name: "Example Org"})

    sign_up_fixture(%{email: "other@example.com", organisation_name: "Acme"})

    assert {{:error, :not_acme}, stdout, ""} = demo()

    assert stdout ==
             "Run this command on an instance set up with the organisation name Acme. This " <>
               "instance's organisation has the slug #{other.slug}.\n"

    refute Repo.exists?(Run)
    refute Accounts.get_user_by_email("dana@example.com")
  end

  test "refuses an Acme whose Main has a node, and makes nothing" do
    %{scope: scope, workspace: main} = set_up_acme()
    {:ok, _node} = Apiary.Nodes.create_node(scope, %{"kind" => "node", "name" => "laptop"})

    assert {{:error, :filled}, _stdout, ""} = demo()
    assert count(from n in Node, where: n.workspace_id == ^main.id) == 1
    refute Repo.exists?(Run)
  end

  test "refuses an Acme without its workspace Main" do
    %{workspace: main} = set_up_acme()

    now = DateTime.utc_now()

    Repo.update_all(from(w in Workspace, where: w.id == ^main.id),
      set: [
        deletion_marked_at: now,
        purge_after: DateTime.add(now, 30, :day),
        purge_trigger: "grace_period"
      ]
    )

    assert {{:error, :no_main}, stdout, ""} = demo()

    assert stdout ==
             "Create the workspace Main at /acme/set-up, then run this command again. The " <>
               "organisation acme has no workspace main.\n"
  end
end
