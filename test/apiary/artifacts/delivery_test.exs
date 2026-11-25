defmodule Apiary.Artifacts.DeliveryTest do
  # The delivery columns of `artifact_versions` and `Apiary.Artifacts.Delivery`: the checks
  # the database keeps on them, and the address of a version's previous delivery.
  use Apiary.DataCase, async: true

  import Apiary.DeliveryFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Adapters.ChangeRequest
  alias Apiary.Artifacts.{Delivery, Version}

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

  defp artifact!(work_item, type, name), do: artifact_fixture(work_item, type, name)
  defp version!(artifact, number, attrs \\ []), do: version_fixture(artifact, number, attrs)

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

    test "refuse, in the database, a state, a failure, a detail or a reply that is none of theirs",
         %{
           artifact: artifact
         } do
      version = version!(artifact, 1)

      for {column, value} <- [
            delivery: "queued",
            delivery_failure: "item_gone",
            delivery_failure: "Refused",
            delivery_detail: "",
            delivery_detail: String.duplicate("é", 1001),
            delivery_detail: "Shorten it.\nThen try again.",
            delivery_detail: "Shorten it.\u2028Then try again.",
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

    test "keep the target they went to, and lose it with the target's row", %{
      work_item: work_item,
      artifact: artifact
    } do
      target =
        target_fixture(%{
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id
        })

      version = version!(artifact, 1, delivery: :sent, delivery_target_id: target.id)
      assert Repo.get!(Version, version.id).delivery_target_id == target.id

      Repo.delete!(target)

      assert %{delivery: :sent, delivery_target_id: nil, workspace_id: workspace_id} =
               Repo.get!(Version, version.id)

      assert workspace_id == work_item.workspace_id
    end

    test "refuse a target of another workspace", %{work_item: work_item, artifact: artifact} do
      other = work_item_fixture(scope_fixture())

      target =
        target_fixture(%{
          organisation_id: other.organisation_id,
          workspace_id: other.workspace_id
        })

      assert_raise Ecto.ConstraintError, ~r/delivery_target_id_fkey/, fn ->
        version!(artifact, 1, delivery: :sent, delivery_target_id: target.id)
      end

      assert work_item.workspace_id != other.workspace_id
    end

    test "list the failure reasons of a change request in changes-failed.schema.json, invalid and target_removed" do
      schema = @failed_schema |> File.read!() |> Jason.decode!()
      reasons = get_in(schema, ["then", "properties", "reason", "enum"])

      assert Enum.sort(Version.delivery_failures()) ==
               Enum.sort(Enum.map(["invalid", "target_removed" | reasons], &String.to_atom/1))
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
    defp validated(changes) do
      ChangeRequest.validate(
        Map.merge(
          %{
            "kind" => "change_request",
            "change_request_id" => "av_7k2m9q4v1x8z3c5d",
            "change_kind" => "reply",
            "target" => %{"collection" => "SUPPORT"},
            "title" => "Delivery dates",
            "text" => "",
            "data" => %{}
          },
          changes
        )
      )
    end

    defp invalid_result do
      assert {:error, %{valid: false}} = result = validated(%{"title" => "Delivery\u{200B}dates"})
      result
    end

    # The detail that `record_invalid/2` stores for `result`.
    defp detail(artifact, result) do
      version = version!(artifact, System.unique_integer([:positive]))
      assert {:ok, %Version{delivery_detail: detail}} = Delivery.record_invalid(version, result)
      assert Repo.get!(Version, version.id).delivery_detail == detail
      detail
    end

    test "stores the first member that failed as the detail", %{artifact: artifact} do
      assert detail(artifact, invalid_result()) == "#/title"
      assert detail(artifact, validated(%{"text" => "a" <> <<0>>})) == "#/text"

      assert detail(artifact, validated(%{"data" => "branch"})) == "#/data"
    end

    test "stores the entry, #, when the failure is at the entry itself", %{artifact: artifact} do
      assert {:error, %{valid: false}} =
               result = ChangeRequest.validate(%{"kind" => "change_request"})

      assert detail(artifact, result) == "#"
    end

    defp summary_at(place),
      do:
        {:error, %{valid: false, count: 1, errors: [%{kind: :pattern, instanceLocation: place}]}}

    test "ends the detail before a member name that a line cannot have, and cuts it", %{
      artifact: artifact
    } do
      summary = &summary_at/1

      assert detail(artifact, summary.("#/data/a\u{200B}b/c")) == "#/data"
      assert detail(artifact, summary.("#/data/a\u{200D}b/c")) == "#/data/a\u{200D}b/c"

      assert detail(artifact, summary.("#/data/" <> String.duplicate("é", 1200)))
             |> String.length() == 1000
    end

    test "cuts the detail by code points, as the check counts them", %{artifact: artifact} do
      # 600 graphemes of two code points each: a cut by graphemes would keep 1207.
      stored = detail(artifact, summary_at("#/data/" <> String.duplicate("e\u0301", 600)))

      assert length(String.codepoints(stored)) == 1000
      assert String.starts_with?(stored, "#/data/e\u0301")
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

      assert Delivery.record_invalid(version, validated(%{})) == {:ok, version}
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

  describe "the report of an adapter" do
    setup %{work_item: work_item, artifact: artifact} do
      target =
        target_fixture(%{
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id,
          collection_external_ref: "R_1001"
        })

      sent = version!(artifact, 1, delivery: :sent, delivery_target_id: target.id)
      %{target: target, sent: sent}
    end

    defp submitted(version, extra \\ %{}) do
      Map.merge(
        %{
          change_request_id: version.public_id,
          collection: "R_1001",
          reply: %{"action" => "created", "address" => %{"url" => "https://x.example/p/1"}}
        },
        extra
      )
    end

    defp refused(version, extra \\ %{}) do
      Map.merge(
        %{
          change_request_id: version.public_id,
          collection: "R_1001",
          reason: :refused,
          detail: nil
        },
        extra
      )
    end

    test "find_sent/3 finds the version of the adapter, by id and collection", ctx do
      assert %Version{id: id} =
               Delivery.find_sent(ctx.target.adapter_id, ctx.sent.public_id, "R_1001")

      assert id == ctx.sent.id
    end

    test "find_sent/3 finds nothing for any other case", ctx do
      adapter_id = ctx.target.adapter_id
      other = bare_adapter_fixture()

      assert Delivery.find_sent(adapter_id, "av_0000000000000000", "R_1001") == nil
      assert Delivery.find_sent(other.id, ctx.sent.public_id, "R_1001") == nil
      assert Delivery.find_sent(adapter_id, ctx.sent.public_id, "R_2002") == nil

      for state <- [nil, :delivered, :failed] do
        version =
          version!(ctx.artifact, System.unique_integer([:positive]),
            delivery: state,
            delivery_target_id: ctx.target.id
          )

        assert Delivery.find_sent(adapter_id, version.public_id, "R_1001") == nil
      end

      no_target = version!(ctx.artifact, System.unique_integer([:positive]), delivery: :sent)
      assert Delivery.find_sent(adapter_id, no_target.public_id, "R_1001") == nil

      Repo.delete!(ctx.target)
      assert Delivery.find_sent(adapter_id, ctx.sent.public_id, "R_1001") == nil
    end

    test "delivered/2 stores the reply and the time on a sent version", ctx do
      reply = %{"action" => "created", "address" => %{"url" => "https://x.example/p/1"}}
      before = DateTime.utc_now()

      assert Delivery.delivered(ctx.target.adapter_id, submitted(ctx.sent)) == {:ok, :stored}

      row = Repo.get!(Version, ctx.sent.id)
      assert {row.delivery, row.delivery_reply, row.delivery_failure} == {:delivered, reply, nil}
      assert DateTime.compare(row.delivery_at, before) in [:gt, :eq]
    end

    test "failed/2 stores the reason and the detail on a sent version", ctx do
      detail = "Shorten the title, then try again. The target returned 422."

      assert Delivery.failed(ctx.target.adapter_id, refused(ctx.sent, %{detail: detail})) ==
               {:ok, :stored}

      row = Repo.get!(Version, ctx.sent.id)

      assert {row.delivery, row.delivery_failure, row.delivery_detail, row.delivery_reply} ==
               {:failed, :refused, detail, nil}
    end

    test "the first stored result wins, and a repeat leaves delivery_at as it is", ctx do
      adapter_id = ctx.target.adapter_id
      assert Delivery.delivered(adapter_id, submitted(ctx.sent)) == {:ok, :stored}
      first = Repo.get!(Version, ctx.sent.id)

      assert Delivery.delivered(
               adapter_id,
               submitted(ctx.sent, %{
                 reply: %{"action" => "kept", "address" => %{"url" => "https://x.example/other"}}
               })
             ) ==
               {:ok, :ignored}

      assert Delivery.failed(adapter_id, refused(ctx.sent)) == {:ok, :ignored}
      assert Repo.get!(Version, ctx.sent.id) == first

      failed = version!(ctx.artifact, 2, delivery: :sent, delivery_target_id: ctx.target.id)
      assert Delivery.failed(adapter_id, refused(failed)) == {:ok, :stored}
      failed_row = Repo.get!(Version, failed.id)
      assert Delivery.delivered(adapter_id, submitted(failed)) == {:ok, :ignored}
      assert Delivery.failed(adapter_id, refused(failed, %{reason: :too_long})) == {:ok, :ignored}
      assert Repo.get!(Version, failed.id) == failed_row
    end

    test "changes nothing for another adapter, another collection, an unknown id or a version not sent",
         ctx do
      other = bare_adapter_fixture()

      done =
        version!(ctx.artifact, 2,
          delivery: :failed,
          delivery_failure: :refused,
          delivery_target_id: ctx.target.id
        )

      assert Delivery.delivered(other.id, submitted(ctx.sent)) == {:ok, :ignored}

      assert Delivery.failed(ctx.target.adapter_id, refused(ctx.sent, %{collection: "R_2"})) ==
               {:ok, :ignored}

      assert Delivery.delivered(
               ctx.target.adapter_id,
               submitted(ctx.sent, %{change_request_id: "av_0000000000000000"})
             ) == {:ok, :ignored}

      assert Delivery.delivered(ctx.target.adapter_id, submitted(done)) == {:ok, :ignored}
      assert Repo.get!(Version, ctx.sent.id).delivery == :sent
    end

    test "the next entry's previous.address is the address of the reply that was stored", ctx do
      assert Delivery.delivered(ctx.target.adapter_id, submitted(ctx.sent)) == {:ok, :stored}
      next = version!(ctx.artifact, 2)

      assert Delivery.previous_address(next) == %{"url" => "https://x.example/p/1"}
    end
  end
end
