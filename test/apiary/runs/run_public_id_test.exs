defmodule Apiary.Runs.RunPublicIdTest do
  # A run's id in Qory Apiary, `rn_` and 16 characters: set by the receiver and by a
  # registration when they create the run, or by the column's default, `run_public_id()`,
  # for a row written without one. The node's run id stays the run's subject.
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.PublicId
  alias Apiary.Runs.{Batch, Ingest, Registration, Run}

  @format ~r/\Arn_[0-9a-hjkmnp-tv-z]{16}\z/

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  test "new_public_id/0 and public_id?/1 are of the shape `Apiary.PublicId` makes" do
    ids = for _ <- 1..50, do: Run.new_public_id()

    for id <- ids do
      assert id =~ @format
      assert PublicId.valid?("rn", id)
      assert Run.public_id?(id)
    end

    assert ids |> Enum.uniq() |> length() == 50

    for bad <- [
          nil,
          "",
          "rn_",
          "rn_000000000000000",
          "rn_000000000000000u",
          "RN_0000000000000000",
          "ws_0000000000000000",
          Ecto.UUID.generate()
        ],
        do: refute(Run.public_id?(bad))
  end

  test "a row written without an id gets the column's default, which Ecto reads back", %{
    scope: scope
  } do
    one = run_fixture(scope)
    other = run_fixture(scope)

    assert one.public_id =~ @format
    assert other.public_id =~ @format
    assert one.public_id != other.public_id
    assert Repo.get!(Run, one.id).public_id == one.public_id
  end

  test "the receiver sets the id when the first batch creates the run", %{scope: scope} do
    %{access_key: key} = access_key_fixture(scope)
    {subject, events} = first_events()
    {:ok, batch} = events |> Jason.encode!() |> Batch.parse()

    assert {:ok, %{run: %Run{} = run}} = Ingest.ingest(key, batch, %{contract_version: 1})
    assert run.run_id == subject
    assert run.public_id =~ @format
    assert Repo.get!(Run, run.id).public_id == run.public_id

    # A later batch of the run keeps it.
    assert {:ok, %{run: again}} = Ingest.ingest(key, batch, %{contract_version: 1})
    assert again.public_id == run.public_id
  end

  test "a registration sets the id, and its answer carries none", %{scope: scope} do
    %{access_key: key} = contract_key_fixture(scope)
    run_id = Ecto.UUID.generate()

    bytes =
      Jason.encode!(%{
        "version" => 1,
        "run_id" => run_id,
        "time" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "forager_version" => "0.8.0",
        "contract_version" => 1,
        "interval_seconds" => 30,
        "events" => ["*"]
      })

    {:ok, registration} = Registration.parse(Jason.decode!(bytes))
    meta = %{body: bytes, contract_version: 1, instance_id: "i_one"}

    assert {:ok, %{settings: settings, run: %Run{} = run}} =
             Registration.register(key, registration, meta)

    assert run.run_id == run_id
    assert run.public_id =~ @format
    refute settings =~ "rn_"
  end

  test "the check refuses a malformed id, and the index a taken one", %{scope: scope} do
    one = run_fixture(scope)
    other = run_fixture(scope)

    for bad <- ~w(rn_000000000000000 rn_000000000000000u ws_0000000000000000 RN_0000000000000000) do
      assert_raise Postgrex.Error, ~r/runs_public_id_format/, fn ->
        Repo.transaction(fn ->
          Repo.query!("UPDATE runs SET public_id = $1 WHERE id = $2", [
            bad,
            Ecto.UUID.dump!(one.id)
          ])
        end)
      end
    end

    assert_raise Postgrex.Error, ~r/runs_public_id_index/, fn ->
      Repo.transaction(fn ->
        Repo.query!("UPDATE runs SET public_id = $1 WHERE id = $2", [
          other.public_id,
          Ecto.UUID.dump!(one.id)
        ])
      end)
    end
  end

  test "a run's id names it in a URL" do
    run = %Run{public_id: "rn_0123456789abcdef"}
    assert Phoenix.Param.to_param(run) == "rn_0123456789abcdef"
  end
end
