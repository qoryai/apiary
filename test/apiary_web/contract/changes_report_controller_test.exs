defmodule ApiaryWeb.Contract.ChangesReportControllerTest do
  # `POST /v1/work-items/changes/submitted`, an adapter's reply for a change request, and
  # the `change_request_id` branch of `POST /v1/work-items/changes/failed`, its report that
  # one failed, through `ApiaryWeb.Contract.AdapterRequest`: the contract's bodies, each a
  # signed 204 that stores the result with the version; the contract's invalid bodies and
  # the time's window; 403 forbidden first; a signed 204 that changes nothing for an id of no
  # sent version of the adapter's target, and for a version with a result already.
  #
  # The window's edge is tested at 301 seconds, under the contract's clock pinned to one
  # second (`pin_clock/0`), so a second ticking over between the test and the server
  # moves nothing. The clock is the application's environment, so this module is not async.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.DeliveryFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures, only: [work_item_fixture: 1]

  alias Apiary.{Edition, Repo}
  alias Apiary.Artifacts.{Delivery, Version}
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory

  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)
  @submitted "/v1/work-items/changes/submitted"
  @failed "/v1/work-items/changes/failed"
  @invalid %{"error" => "invalid_request"}
  @forbidden %{"error" => "forbidden"}
  @collection "R_1001"

  # The edition narrows the rights of an adapter's key: its role reports on no change request.
  defmodule NoReport do
    @moduledoc false
    def check(_scope, :"change_request.report", _subject), do: {:error, :forbidden}
    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{adapter: adapter, access_key: key, pair: pair} = connectable_adapter_fixture()
    work_item = work_item_fixture(scope)

    target =
      target_fixture(%{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        adapter_id: adapter.id,
        collection_external_ref: @collection
      })

    %{
      adapter: adapter,
      key: key,
      seed: pair.secret,
      target: target,
      artifact: artifact_fixture(work_item, "pull-request", "t-1")
    }
  end

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()

  defp fixtures(pattern) do
    @fixtures
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @fixtures))
    |> Enum.sort()
  end

  defp pin_clock do
    now = System.os_time(:second)
    Application.put_env(:apiary, :contract_now, fn -> now end)
    on_exit(fn -> Application.delete_env(:apiary, :contract_now) end)
  end

  defp now_time(offset \\ 0),
    do: (SignedRequest.now() + offset) |> DateTime.from_unix!() |> DateTime.to_iso8601()

  # A version, number `number` of the artifact, sent to the target: the entry's version.
  defp sent!(ctx, number \\ System.unique_integer([:positive]), attrs \\ []) do
    version_fixture(
      ctx.artifact,
      number,
      Keyword.merge([delivery: :sent, delivery_target_id: ctx.target.id], attrs)
    )
  end

  # The contract's body `path`, for `version`'s entry, as the adapter sends it now.
  defp body(path, version, extra \\ %{}) do
    path
    |> fixture()
    |> Map.merge(%{"time" => now_time(), "change_request_id" => version.public_id})
    |> put_in(["target", "collection"], @collection)
    |> Map.merge(extra)
  end

  # The contract's body `path` as the adapter sends it now, with no other change: for a
  # body that the contract refuses, whatever it names.
  defp as_written(path), do: path |> fixture() |> Map.put("time", now_time())

  defp send_post(ctx, target, body, opts \\ []) do
    signed_post(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      body,
      target: target,
      content_type: "application/json",
      delivery: nil
    )
  end

  defp no_content!(conn) do
    assert conn.status == 204
    assert conn.resp_body == ""
    assert signed_answer?(conn)
  end

  defp row(version), do: Repo.get!(Version, version.id)

  defp reply_of(body), do: Map.take(body, ~w(action address data))

  describe "a reply" do
    test "each of the contract's replies is a signed 204 that stores it as delivered", ctx do
      paths = fixtures("changes-submitted/*.json")
      assert length(paths) == 6

      for path <- paths do
        version = sent!(ctx)
        written = body(path, version)
        before = DateTime.utc_now()

        ctx |> send_post(@submitted, written) |> no_content!()

        stored = row(version)
        assert {stored.delivery, stored.delivery_reply} == {:delivered, reply_of(written)}, path
        assert stored.delivery_failure == nil
        assert DateTime.compare(stored.delivery_at, before) in [:gt, :eq]
      end
    end

    test "the next entry's previous.address is the address of the stored reply", ctx do
      version = sent!(ctx, 1)
      written = body("changes-submitted/pull-request-created.json", version)
      ctx |> send_post(@submitted, written) |> no_content!()

      next = version_fixture(ctx.artifact, 2)
      assert Delivery.previous_address(next) == written["address"]
    end

    test "the contract's invalid replies, and the ones the control plane refuses, are 400",
         ctx do
      version = sent!(ctx)

      bodies =
        Enum.map(fixtures("invalid/changes-submitted-*.json"), &as_written/1) ++
          [as_written("refused-by-control-plane/changes-submitted-address-other-host.json")]

      assert length(bodies) == 11

      for written <- bodies do
        conn = send_post(ctx, @submitted, written)
        assert json_response(conn, 400) == @invalid, inspect(written)
        assert signed_answer?(conn)
      end

      repeated =
        "refused-by-control-plane/changes-submitted-data-repeated-member.json"
        |> then(&File.read!(Path.join(@fixtures, &1)))
        |> String.replace("av_7k2m9q4v1x8z3c5d", version.public_id)

      conn = send_post(ctx, @submitted, repeated)
      assert json_response(conn, 400) == @invalid
      assert row(version).delivery == :sent
    end

    test "a time more than 300 seconds off is 401, unsigned", ctx do
      pin_clock()
      version = sent!(ctx)

      for offset <- [-301, 301] do
        written = body("changes-submitted/reply.json", version, %{"time" => now_time(offset)})
        conn = send_post(ctx, @submitted, written)
        assert json_response(conn, 401) == %{"error" => "unauthorized"}
        assert unsigned_answer?(conn)
      end

      assert row(version).delivery == :sent
    end

    test "403 forbidden comes first, for any id, and changes nothing", ctx do
      version = sent!(ctx)
      Edition.put_test_stub(NoReport)

      for id <- [version.public_id, "av_0000000000000000"] do
        written = body("changes-submitted/reply.json", version, %{"change_request_id" => id})
        conn = send_post(ctx, @submitted, written)
        assert json_response(conn, 403) == @forbidden
        assert signed_answer?(conn)
      end

      assert row(version).delivery == :sent
    end

    test "a signed 204 changes nothing for a version that is no entry of the adapter", ctx do
      version = sent!(ctx)
      other = connectable_adapter_fixture()

      done =
        sent!(ctx, System.unique_integer([:positive]),
          delivery: :failed,
          delivery_failure: :refused
        )

      unsent = sent!(ctx, System.unique_integer([:positive]), delivery: nil)
      gone = sent!(ctx)
      Repo.delete!(Repo.get!(Apiary.Runs.Target, ctx.target.id))
      before = Enum.map([version, done, unsent, gone], &row/1)

      written = body("changes-submitted/reply.json", version)

      ctx
      |> send_post(@submitted, written, key_id: other.access_key.key_id, seed: other.pair.secret)
      |> no_content!()

      for case_body <- [
            body("changes-submitted/reply.json", version, %{
              "change_request_id" => "av_0000000000000000"
            }),
            body("changes-submitted/reply.json", version, %{"target" => %{"collection" => "R_2"}}),
            body("changes-submitted/reply.json", done),
            body("changes-submitted/reply.json", unsent),
            body("changes-submitted/reply.json", gone)
          ] do
        ctx |> send_post(@submitted, case_body) |> no_content!()
      end

      assert Enum.map([version, done, unsent, gone], &row/1) == before
    end

    test "the first stored reply wins, and a repeat leaves delivery_at as it is", ctx do
      version = sent!(ctx)
      ctx |> send_post(@submitted, body("changes-submitted/reply.json", version)) |> no_content!()
      first = row(version)

      again = body("changes-submitted/pull-request-created.json", version)
      ctx |> send_post(@submitted, again) |> no_content!()

      ctx
      |> send_post(@failed, failed_body("change-request-refused.json", version))
      |> no_content!()

      assert row(version) == first
    end
  end

  # A failure's body for `version`.
  defp failed_body(name, version), do: body("changes-failed/" <> name, version)

  describe "a failure of a change request" do
    test "each of the contract's reports is a signed 204 that stores the reason", ctx do
      paths = fixtures("changes-failed/change-request-*.json")
      assert length(paths) == 11

      for path <- paths do
        version = sent!(ctx)
        written = body(path, version)

        ctx |> send_post(@failed, written) |> no_content!()

        stored = row(version)
        assert stored.delivery == :failed, path
        assert Atom.to_string(stored.delivery_failure) == written["reason"], path
        assert stored.delivery_detail == written["detail"], path
        assert stored.delivery_reply == nil
        assert stored.delivery_at
      end
    end

    test "the contract's invalid reports of a change request are 400", ctx do
      version = sent!(ctx)

      for path <- fixtures("invalid/changes-failed-change-request-*.json") do
        conn = send_post(ctx, @failed, as_written(path))
        assert json_response(conn, 400) == @invalid, path
        assert signed_answer?(conn)
      end

      assert row(version).delivery == :sent
    end

    test "403 forbidden comes first for a change request, and changes nothing", ctx do
      version = sent!(ctx)
      Edition.put_test_stub(NoReport)

      conn = send_post(ctx, @failed, failed_body("change-request-refused.json", version))
      assert json_response(conn, 403) == @forbidden
      assert signed_answer?(conn)
      assert row(version).delivery == :sent
    end

    test "a signed 204 changes nothing for a version that is no entry of the adapter", ctx do
      version = sent!(ctx)
      other = connectable_adapter_fixture()

      done =
        sent!(ctx, System.unique_integer([:positive]),
          delivery: :delivered,
          delivery_reply: %{"action" => "created"}
        )

      before = Enum.map([version, done], &row/1)

      written = failed_body("change-request-refused.json", version)

      ctx
      |> send_post(@failed, written, key_id: other.access_key.key_id, seed: other.pair.secret)
      |> no_content!()

      ctx
      |> send_post(
        @failed,
        failed_body("change-request-refused.json", version)
        |> put_in(["target", "collection"], "R_2")
      )
      |> no_content!()

      ctx |> send_post(@failed, failed_body("change-request-refused.json", done)) |> no_content!()

      ctx
      |> send_post(
        @failed,
        failed_body("change-request-refused.json", version)
        |> Map.put("change_request_id", "av_0000000000000000")
      )
      |> no_content!()

      assert Enum.map([version, done], &row/1) == before
    end

    test "the first stored failure wins, and a repeat leaves delivery_at as it is", ctx do
      version = sent!(ctx)

      ctx
      |> send_post(@failed, failed_body("change-request-refused.json", version))
      |> no_content!()

      first = row(version)

      ctx
      |> send_post(@failed, failed_body("change-request-too-long.json", version))
      |> no_content!()

      ctx |> send_post(@submitted, body("changes-submitted/reply.json", version)) |> no_content!()

      assert row(version) == first
      assert first.delivery_failure == :refused
    end
  end
end
