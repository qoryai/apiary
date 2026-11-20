defmodule Apiary.Artifacts.DeliveryTest do
  # The delivery columns of `artifact_versions` and `Apiary.Artifacts.Delivery`: the checks
  # the database keeps on them, and the address of a version's previous delivery.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Adapters.ChangeRequest
  alias Apiary.Artifacts.{Artifact, Delivery, Version}

  @moduletag needs: :workflow_model

  @failed_schema Path.expand(
                   "../../fixtures/contract/integration/v1/changes-failed.schema.json",
                   __DIR__
                 )

  setup do
    scope = scope_fixture()
    work_item = work_item_fixture(scope)
    %{work_item: work_item, artifact: artifact!(work_item, "reply", "t-1")}
  end

  defp artifact!(work_item, type, name) do
    Repo.insert!(%Artifact{
      public_id: Apiary.PublicId.generate("af"),
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      type: type,
      name: name,
      inserted_at: ~U[2026-11-20 08:00:00.000000Z]
    })
  end

  defp version!(artifact, number, attrs \\ []) do
    Repo.insert!(
      struct!(
        %Version{
          public_id: Apiary.PublicId.generate("av"),
          organisation_id: artifact.organisation_id,
          workspace_id: artifact.workspace_id,
          artifact_id: artifact.id,
          number: number,
          writer: :person,
          inserted_at: ~U[2026-11-20 09:00:00.000000Z]
        },
        attrs
      )
    )
  end

  defp reply(path),
    do: %{"action" => "created", "address" => %{"url" => "https://x.example/" <> path}}

  describe "the delivery columns" do
    test "are empty on a version stored before them", %{artifact: artifact} do
      version = artifact |> version!(1) |> then(&Repo.get!(Version, &1.id))

      assert {version.delivery, version.delivery_reply, version.delivery_failure,
              version.delivery_at} == {nil, nil, nil, nil}
    end

    test "take each delivery state, the reply and the failure", %{artifact: artifact} do
      at = ~U[2026-11-20 10:00:00.000000Z]

      sent = version!(artifact, 1, delivery: :sent)

      delivered =
        version!(artifact, 2, delivery: :delivered, delivery_reply: reply("1"), delivery_at: at)

      failed =
        version!(artifact, 3, delivery: :failed, delivery_failure: :target_gone, delivery_at: at)

      assert Repo.get!(Version, sent.id).delivery == :sent
      assert %{delivery: :delivered, delivery_at: ^at} = Repo.get!(Version, delivered.id)
      assert Repo.get!(Version, delivered.id).delivery_reply == reply("1")
      assert %{delivery: :failed, delivery_failure: :target_gone} = Repo.get!(Version, failed.id)
    end

    test "refuse, in the database, a state, a failure or a reply that is none of theirs", %{
      artifact: artifact
    } do
      version = version!(artifact, 1)

      for {column, value} <- [
            delivery: "queued",
            delivery_failure: "item_gone",
            delivery_failure: "Refused",
            delivery_reply: "[]"
          ] do
        assert_raise Postgrex.Error, ~r/artifact_versions_#{column}_check/, fn ->
          Repo.query!(
            "UPDATE artifact_versions SET #{column} = $1#{if column == :delivery_reply, do: "::jsonb"} WHERE id = $2",
            [value, Ecto.UUID.dump!(version.id)]
          )
        end
      end
    end

    test "list the failure reasons of a change request in changes-failed.schema.json, and invalid" do
      schema = @failed_schema |> File.read!() |> Jason.decode!()
      reasons = get_in(schema, ["then", "properties", "reason", "enum"])

      assert Enum.sort(Version.delivery_failures()) ==
               Enum.sort(Enum.map(["invalid" | reasons], &String.to_atom/1))
    end
  end

  describe "previous_address/1" do
    test "is nil for the first version of the artifact", %{artifact: artifact} do
      assert Delivery.previous_address(version!(artifact, 1)) == nil
    end

    test "is the address of the newest reply of the artifact", %{artifact: artifact} do
      version!(artifact, 1,
        delivery: :delivered,
        delivery_reply: reply("old"),
        delivery_at: ~U[2026-11-20 10:00:00.000000Z]
      )

      version!(artifact, 2,
        delivery: :delivered,
        delivery_reply: reply("new"),
        delivery_at: ~U[2026-11-20 11:00:00.000000Z]
      )

      assert Delivery.previous_address(version!(artifact, 3)) ==
               %{"url" => "https://x.example/new"}
    end

    test "is ordered by delivery_at, not by version number", %{artifact: artifact} do
      version!(artifact, 1,
        delivery: :delivered,
        delivery_reply: reply("later"),
        delivery_at: ~U[2026-11-20 12:00:00.000000Z]
      )

      version!(artifact, 2,
        delivery: :delivered,
        delivery_reply: reply("earlier"),
        delivery_at: ~U[2026-11-20 10:00:00.000000Z]
      )

      assert Delivery.previous_address(version!(artifact, 3)) ==
               %{"url" => "https://x.example/later"}
    end

    test "falls back to inserted_at on equal delivery_at, and puts no delivery_at last", %{
      artifact: artifact
    } do
      at = ~U[2026-11-20 10:00:00.000000Z]

      version!(artifact, 1,
        delivery: :delivered,
        delivery_reply: reply("a"),
        delivery_at: at,
        inserted_at: ~U[2026-11-20 09:00:00.000000Z]
      )

      version!(artifact, 2,
        delivery: :delivered,
        delivery_reply: reply("b"),
        delivery_at: at,
        inserted_at: ~U[2026-11-20 09:30:00.000000Z]
      )

      version!(artifact, 3, delivery: :delivered, delivery_reply: reply("none"))

      assert Delivery.previous_address(version!(artifact, 4)) == %{"url" => "https://x.example/b"}
    end

    test "leaves out the version itself, a failure, a version with no reply, and other artifacts",
         %{
           work_item: work_item,
           artifact: artifact
         } do
      other = artifact!(work_item, "reply", "t-2")

      version!(other, 1,
        delivery: :delivered,
        delivery_reply: reply("other"),
        delivery_at: ~U[2026-11-20 13:00:00.000000Z]
      )

      version!(artifact, 1,
        delivery: :failed,
        delivery_failure: :refused,
        delivery_at: ~U[2026-11-20 13:00:00.000000Z]
      )

      version!(artifact, 2, delivery: :sent)

      own =
        version!(artifact, 3,
          delivery: :delivered,
          delivery_reply: reply("self"),
          delivery_at: ~U[2026-11-20 14:00:00.000000Z]
        )

      assert Delivery.previous_address(own) == nil
    end

    test "is nil when the newest reply has no address", %{artifact: artifact} do
      version!(artifact, 1,
        delivery: :delivered,
        delivery_reply: reply("old"),
        delivery_at: ~U[2026-11-20 10:00:00.000000Z]
      )

      version!(artifact, 2,
        delivery: :delivered,
        delivery_reply: %{"data" => %{}},
        delivery_at: ~U[2026-11-20 11:00:00.000000Z]
      )

      assert Delivery.previous_address(version!(artifact, 3)) == nil
    end
  end

  describe "record_invalid/2" do
    defp validated(title) do
      ChangeRequest.validate(%{
        "kind" => "change_request",
        "change_request_id" => "av_7k2m9q4v1x8z3c5d",
        "change_kind" => "reply",
        "target" => %{"collection" => "SUPPORT"},
        "title" => title,
        "text" => "",
        "data" => %{}
      })
    end

    defp invalid_result do
      assert {:error, %{valid: false}} = result = validated("Delivery\u{200B}dates")
      result
    end

    test "stores a failed delivery with the reason invalid, and sends no reply", %{
      artifact: artifact
    } do
      version = version!(artifact, 1)
      before = DateTime.utc_now()

      assert {:ok, stored} = Delivery.record_invalid(version, invalid_result())

      row = Repo.get!(Version, version.id)
      assert {row.delivery, row.delivery_failure, row.delivery_reply} == {:failed, :invalid, nil}
      assert DateTime.compare(row.delivery_at, before) in [:gt, :eq]

      assert {stored.delivery, stored.delivery_failure, stored.delivery_at} ==
               {row.delivery, row.delivery_failure, row.delivery_at}
    end

    test "changes nothing for a valid entry", %{artifact: artifact} do
      version = version!(artifact, 1)

      assert Delivery.record_invalid(version, validated("Delivery dates")) == {:ok, version}
      assert Repo.get!(Version, version.id).delivery == nil
    end

    test "leaves a version that has a delivery as it is", %{artifact: artifact} do
      at = ~U[2026-11-20 10:00:00.000000Z]

      for attrs <- [
            [delivery: :sent],
            [delivery: :delivered, delivery_reply: reply("1"), delivery_at: at],
            [delivery: :failed, delivery_failure: :refused, delivery_at: at]
          ] do
        version = version!(artifact, System.unique_integer([:positive]), attrs)

        assert Delivery.record_invalid(version, invalid_result()) == {:error, :delivery_set}
        row = Repo.get!(Version, version.id)

        assert {row.delivery, row.delivery_failure, row.delivery_at} ==
                 {version.delivery, version.delivery_failure, version.delivery_at}
      end
    end
  end
end
