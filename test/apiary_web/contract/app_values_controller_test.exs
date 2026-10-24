defmodule ApiaryWeb.Contract.AppValuesControllerTest do
  # `POST /v1/adapter/secrets`, an adapter storing the secrets it keeps in Qory Apiary,
  # sealed to the instance's signing key, through `ApiaryWeb.Contract.AdapterRequest`: the
  # signed 204 and what it stores, the replacement, the refusals in their order, the
  # contract's invalid fixtures, and no value in an entry or a log line.
  #
  # Not async: a test changes the adapters `QORY_INSTALLED_ADAPTERS` lists.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import Apiary.AccessKeysFixtures,
    only: [enrolled_key_fixture: 2, installed_key_fixture: 1, node_key_fixture: 2]

  import Apiary.DescriptionFixtures, only: [contract_description: 0]

  import Apiary.ContractFixtures,
    only: [signed_get: 5, signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Repo, SigningKey}
  alias Apiary.Audit.Entry
  alias Apiary.Contract.Ed25519
  alias Apiary.Nodes.Node
  alias Apiary.Secrets.{AdapterSealing, Hpke, Instance, InstanceDataKey, InstanceSecretValue}
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory

  @path "/v1/adapter/secrets"
  @invalid %{"error" => "invalid_request"}
  # The contract's refusal fixture, vendored from the commit in `.integration-contract-ref`.
  @unknown_server_key "../../fixtures/integration-contract/adapter/refusal/unknown-server-key.json"
                      |> Path.expand(__DIR__)
                      |> File.read!()
                      |> Jason.decode!()
  @unauthorized %{"error" => "unauthorized"}
  @signing_key "fixture-signing-key-for-tests-only\nsecond line"
  @event_secret "fixture-event-secret-for-tests-only"

  setup do
    saved_list = Application.fetch_env(:apiary, :installed_adapters)

    on_exit(fn ->
      case saved_list do
        {:ok, names} -> Application.put_env(:apiary, :installed_adapters, names)
        :error -> Application.delete_env(:apiary, :installed_adapters)
      end
    end)

    adapter_ctx(connectable_adapter_fixture())
  end

  # An adapter whose description lists the secrets `event-secret` and `signing-key`.
  defp adapter_ctx(%{adapter: adapter, access_key: key, pair: pair}) do
    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
        set: [secret_names: ["event-secret", "signing-key"]]
      )

    %{adapter: Repo.reload!(adapter), key: key, seed: pair.secret}
  end

  defp now_time(offset \\ 0),
    do: (SignedRequest.now() + offset) |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp plaintext(pairs) do
    Jason.encode!(%{
      "version" => 1,
      "secrets" => for({name, value} <- pairs, do: %{"name" => name, "value" => value})
    })
  end

  # An upload of `pt`, sealed to the instance's signing key, or to `opts[:to]`, a signing
  # key, under the adapter id and access key id of `ctx`, or of `opts`.
  defp upload(ctx, pt, opts \\ []) do
    to = Keyword.get(opts, :to, SigningKey.current())
    server_key = Ed25519.encode(SigningKey.public_key(to))
    {:ok, pk} = Ed25519.x25519_public_key(SigningKey.public_key(to))
    adapter_id = Keyword.get(opts, :adapter_id, ctx.adapter.public_id)
    key_id = Keyword.get(opts, :key_id, ctx.key.key_id)

    {:ok, enc, ct} =
      Hpke.seal(
        fn -> :crypto.strong_rand_bytes(32) end,
        pk,
        AdapterSealing.upload_info(server_key),
        AdapterSealing.aad(adapter_id, key_id),
        pt
      )

    %{
      "version" => 1,
      "time" => Keyword.get(opts, :time, now_time()),
      "sealed" => %{
        "suite" => "x25519-sha256-aes256gcm",
        "server_key" => Keyword.get(opts, :server_key, server_key),
        "enc" => Ed25519.encode(enc),
        "ct" => Ed25519.encode(ct)
      }
    }
  end

  defp send_post(ctx, body, opts \\ []) do
    signed_post(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      body,
      target: @path,
      content_type: "application/json",
      delivery: nil
    )
  end

  defp stored(adapter) do
    {:ok, %{revision: revision, values: values}} =
      Instance.reveal_app_values_for_sealing(Repo.reload!(adapter))

    {revision, for(%InstanceSecretValue{value_id: id, value: value} <- values, do: {id, value})}
  end

  defp entries(adapter) do
    Repo.all(
      from e in Entry,
        where: e.action == "adapter.app_values_set" and e.subject_id == ^adapter.id,
        order_by: e.inserted_at
    )
  end

  describe "an upload" do
    test "is stored, signed 204, with one entry that has no value", ctx do
      pt = plaintext([{"signing-key", @signing_key}, {"event-secret", @event_secret}])
      conn = send_post(ctx, upload(ctx, pt))

      assert conn.status == 204
      assert conn.resp_body == ""
      assert signed_answer?(conn)

      assert stored(ctx.adapter) ==
               {1, [{"event-secret", @event_secret}, {"signing-key", @signing_key}]}

      assert [entry] = entries(ctx.adapter)
      assert {entry.actor_kind, entry.actor_id} == {:access_key, ctx.key.id}

      assert %{
               "names" => ["event-secret", "signing-key"],
               "revision" => 1,
               "replaced" => false,
               "reference" => "builtin:sec_" <> _
             } = entry.details

      refute inspect(entry) =~ "fixture-"
    end

    test "replaces every secret stored before, and an empty list leaves none", ctx do
      conn = send_post(ctx, upload(ctx, plaintext([{"signing-key", "one"}])))
      assert conn.status == 204

      conn = send_post(ctx, upload(ctx, plaintext([{"event-secret", "two"}])))
      assert conn.status == 204
      assert stored(ctx.adapter) == {2, [{"event-secret", "two"}]}

      conn = send_post(ctx, upload(ctx, plaintext([])))
      assert conn.status == 204
      assert stored(ctx.adapter) == {3, []}

      assert [%{details: %{"replaced" => false}}, %{details: %{"replaced" => true}}, _third] =
               entries(ctx.adapter)
    end
  end

  describe "a description that lists secrets" do
    test "is accepted at start-up; an upload of its names is stored, and of another refused" do
      %{adapter: adapter, access_key: key, pair: pair} = connectable_adapter_fixture()
      ctx = %{adapter: adapter, key: key, seed: pair.secret}

      description =
        put_in(contract_description(), ["roles", "source", "secrets"], [
          "signing-key",
          "event-secret"
        ])

      start = %{
        "version" => 1,
        "time" => now_time(),
        "connect_url" => "https://tracker-adapter.acme.example/connect",
        "sync" => %{
          "default_interval" => 900,
          "minimum_interval" => 300,
          "sends_changes" => false
        },
        "description" => description
      }

      conn =
        signed_post(build_conn(), key.key_id, pair.secret, start,
          target: "/v1/adapter",
          content_type: "application/json",
          delivery: nil
        )

      assert conn.status == 204
      assert Repo.reload!(adapter).secret_names == ["event-secret", "signing-key"]

      pt = plaintext([{"signing-key", @signing_key}, {"event-secret", @event_secret}])
      assert send_post(ctx, upload(ctx, pt)).status == 204

      assert stored(adapter) ==
               {1, [{"event-secret", @event_secret}, {"signing-key", @signing_key}]}

      conn = send_post(ctx, upload(ctx, plaintext([{"webhook-secret", "v"}])))
      assert json_response(conn, 400) == @invalid

      assert stored(adapter) ==
               {1, [{"event-secret", @event_secret}, {"signing-key", @signing_key}]}
    end
  end

  describe "the refusals" do
    test "a plaintext outside the contract, or a name the description does not list, is 400",
         ctx do
      seventeen = for n <- 0..16, do: {"secret-#{n}", "v"}

      for pt <- [
            plaintext(seventeen),
            plaintext([{"signing-key", "a" <> <<0>> <> "b"}]),
            plaintext([{"signing-key", ""}]),
            plaintext([{"Signing-Key", "v"}]),
            plaintext([{"undeclared", "v"}]),
            "not json"
          ] do
        conn = send_post(ctx, upload(ctx, pt))
        assert json_response(conn, 400) == @invalid
        assert signed_answer?(conn)
      end

      assert stored(ctx.adapter) == {nil, []}
      assert entries(ctx.adapter) == []
    end

    test "an envelope sealed to a server key the instance does not hold is 400 unknown_server_key, signed, and stores nothing",
         ctx do
      pt = plaintext([{"signing-key", "v"}])
      other = SigningKey.new(:crypto.strong_rand_bytes(32))

      for body <- [
            upload(ctx, pt, to: other),
            upload(ctx, pt, server_key: Ed25519.encode(SigningKey.public_key(other)))
          ] do
        conn = send_post(ctx, body)
        assert json_response(conn, 400) == @unknown_server_key
        assert signed_answer?(conn)
      end

      assert stored(ctx.adapter) == {nil, []}
      assert entries(ctx.adapter) == []
    end

    test "an envelope sealed to another adapter or access key, or changed, is 400 invalid_request, signed",
         ctx do
      pt = plaintext([{"signing-key", "v"}])
      body = upload(ctx, pt)
      {:ok, <<first, rest::binary>>} = Base.url_decode64(body["sealed"]["ct"], padding: false)

      for body <- [
            upload(ctx, pt, adapter_id: "na_f1xt0re000000000"),
            upload(ctx, pt, key_id: "ak_f1xt0re000000000"),
            put_in(
              body,
              ["sealed", "ct"],
              Ed25519.encode(<<Bitwise.bxor(first, 1), rest::binary>>)
            )
          ] do
        conn = send_post(ctx, body)
        assert json_response(conn, 400) == @invalid
        assert signed_answer?(conn)
      end

      assert stored(ctx.adapter) == {nil, []}
      assert entries(ctx.adapter) == []
    end

    test "the contract's invalid uploads are 400", ctx do
      for name <- ["adapter-secrets-value-in-clear", "adapter-secrets-without-server-key"] do
        assert json_response(send_post(ctx, invalid_upload(ctx, name)), 400) == @invalid, name
      end

      body = upload(ctx, plaintext([]))

      for broken <- [
            Map.delete(body, "sealed"),
            Map.put(body, "version", 2),
            Map.put(body, "more", true),
            put_in(body, ["sealed", "suite"], "x25519-sha256-chacha20poly1305")
          ] do
        assert json_response(send_post(ctx, broken), 400) == @invalid
      end
    end

    test "a time out of the window, or a replay, is 401, unsigned, and stores nothing", ctx do
      pt = plaintext([{"signing-key", "v"}])

      for offset <- [-310, 310] do
        conn = send_post(ctx, upload(ctx, pt, time: now_time(offset)))
        assert json_response(conn, 401) == @unauthorized
        assert unsigned_answer?(conn)
      end

      body = upload(ctx, pt) |> Jason.encode!()
      assert send_post(ctx, body).status == 204
      replayed = send_post(ctx, body)
      assert json_response(replayed, 401) == @unauthorized
      assert unsigned_answer?(replayed)
      assert stored(ctx.adapter) == {1, [{"signing-key", "v"}]}
    end

    test "a key that is not an adapter's is refused, and stores nothing", ctx do
      %{scope: scope} = sign_up_fixture()
      %{access_key: key, pair: pair} = node_key_fixture(scope, node_fixture(scope))
      gateway = %{ctx | key: key, seed: pair.secret}

      conn = send_post(gateway, upload(gateway, plaintext([{"signing-key", "v"}])))
      assert json_response(conn, 401) == @unauthorized
      assert stored(ctx.adapter) == {nil, []}
    end

    test "an installed adapter no longer listed is 404", ctx do
      name = "tracker-#{System.unique_integer([:positive])}"
      Application.put_env(:apiary, :installed_adapters, [name])
      installed = installed_adapter_fixture(name)

      made =
        installed_key_fixture(installed)
        |> Map.put(:adapter, installed)
        |> adapter_ctx()

      Application.put_env(:apiary, :installed_adapters, [])
      conn = send_post(made, upload(made, plaintext([{"signing-key", "v"}])))
      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert stored(made.adapter) == {nil, []}
      assert ctx.adapter.id != made.adapter.id
    end
  end

  defp send_get(ctx, opts \\ []) do
    signed_get(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      Keyword.get(opts, :target, @path),
      opts
    )
  end

  # Opens a delivery with the access key whose Ed25519 seed is `seed`, under `ctx`'s
  # adapter and `key_id`.
  defp open(body, ctx, seed, key_id) do
    %{"sealed" => %{"enc" => enc, "ct" => ct}} = body
    sk = binary_part(:crypto.hash(:sha512, seed), 0, 32)

    Hpke.open(
      sk,
      Base.url_decode64!(enc, padding: false),
      AdapterSealing.delivery_info(key_id),
      AdapterSealing.aad(ctx.adapter.public_id, key_id),
      Base.url_decode64!(ct, padding: false)
    )
  end

  defp seal_entries(adapter) do
    Repo.all(
      from e in Entry,
        where: e.action == "adapter.app_values_seal" and e.subject_id == ^adapter.id,
        order_by: e.inserted_at
    )
  end

  describe "a delivery" do
    test "is the secrets stored, sealed to the asking key, signed 200, with an entry each",
         ctx do
      pt = plaintext([{"signing-key", @signing_key}, {"event-secret", @event_secret}])
      assert send_post(ctx, upload(ctx, pt)).status == 204

      conn = send_get(ctx)
      assert conn.status == 200
      assert signed_answer?(conn)
      body = Jason.decode!(conn.resp_body)
      assert Map.keys(body) |> Enum.sort() == ~w(revision sealed version)
      assert %{"version" => 1, "revision" => 1} = body

      assert %{"suite" => "x25519-sha256-aes256gcm", "access_key_id" => key_id} =
               body["sealed"]

      assert key_id == ctx.key.key_id
      assert Map.keys(body["sealed"]) |> Enum.sort() == ~w(access_key_id ct enc suite)

      assert {:ok, opened} = open(body, ctx, ctx.seed, ctx.key.key_id)

      assert Jason.decode!(opened) == %{
               "version" => 1,
               "secrets" => [
                 %{"name" => "event-secret", "value" => @event_secret},
                 %{"name" => "signing-key", "value" => @signing_key}
               ]
             }

      refute conn.resp_body =~ "fixture-"

      second = send_get(ctx, timestamp: SignedRequest.now() + 1)
      assert second.status == 200
      refute Jason.decode!(second.resp_body)["sealed"]["enc"] == body["sealed"]["enc"]

      assert [entry, _second] = seal_entries(ctx.adapter)
      assert {entry.actor_kind, entry.actor_id} == {:access_key, ctx.key.id}

      assert entry.details == %{
               "access_key_id" => ctx.key.key_id,
               "revision" => 1,
               "names" => ["event-secret", "signing-key"]
             }
    end

    test "with no secret stored is an empty list, sealed", ctx do
      conn = send_get(ctx)
      assert conn.status == 200

      assert open(Jason.decode!(conn.resp_body), ctx, ctx.seed, ctx.key.key_id) ==
               {:ok, ~s({"version":1,"secrets":[]})}
    end

    test "to another key of the adapter is sealed to that key alone", ctx do
      assert send_post(ctx, upload(ctx, plaintext([{"signing-key", "v"}]))).status == 204

      %{access_key: key_b, pair: pair_b} =
        enrolled_key_fixture(instance_admin_scope(), ctx.adapter)

      ctx_b = %{ctx | key: key_b, seed: pair_b.secret}

      body = ctx_b |> send_get() |> Map.fetch!(:resp_body) |> Jason.decode!()
      assert body["sealed"]["access_key_id"] == key_b.key_id
      assert {:ok, _opened} = open(body, ctx, pair_b.secret, key_b.key_id)
      assert open(body, ctx, ctx.seed, key_b.key_id) == :error
      assert open(body, ctx, ctx.seed, ctx.key.key_id) == :error
    end

    test "with a query is 400; a key that is not an adapter's, a replay or a deleted adapter's key is 401",
         ctx do
      assert json_response(send_get(ctx, target: @path <> "?all=1"), 400) == @invalid

      %{scope: scope} = sign_up_fixture()
      %{access_key: key, pair: pair} = node_key_fixture(scope, node_fixture(scope))
      gateway = %{ctx | key: key, seed: pair.secret}
      assert json_response(send_get(gateway), 401) == @unauthorized

      now = SignedRequest.now()
      assert send_get(ctx, timestamp: now).status == 200
      replayed = send_get(ctx, timestamp: now)
      assert json_response(replayed, 401) == @unauthorized
      assert unsigned_answer?(replayed)

      {:ok, _} = Apiary.Adapters.delete_adapter(instance_admin_scope(), ctx.adapter)
      assert json_response(send_get(ctx), 401) == @unauthorized
      assert length(seal_entries(ctx.adapter)) == 1
    end

    test "to an installed adapter no longer listed is 404, with no entry" do
      name = "tracker-#{System.unique_integer([:positive])}"
      Application.put_env(:apiary, :installed_adapters, [name])
      installed = installed_adapter_fixture(name)

      made =
        installed_key_fixture(installed)
        |> Map.put(:adapter, installed)
        |> adapter_ctx()

      Application.put_env(:apiary, :installed_adapters, [])
      assert json_response(send_get(made), 404) == %{"error" => "not_found"}
      assert seal_entries(made.adapter) == []
    end
  end

  describe "the log" do
    test "has no value, also when the values cannot be stored", ctx do
      pt = plaintext([{"signing-key", @signing_key}])

      log =
        capture_log([level: :debug], fn ->
          assert send_post(ctx, upload(ctx, pt)).status == 204
          assert json_response(send_post(ctx, upload(ctx, "not json")), 400) == @invalid
        end)

      refute log =~ "fixture-signing-key"

      # The instance's data key, as stored, no longer unwraps.
      {1, _} =
        Repo.update_all(InstanceDataKey, set: [wrapped_key: :crypto.strong_rand_bytes(60)])

      log =
        capture_log([level: :debug], fn ->
          conn = send_post(ctx, upload(ctx, plaintext([{"signing-key", @event_secret}])))
          assert json_response(conn, 503) == %{"error" => "unavailable"}
        end)

      assert log =~ "the instance's data key cannot be unwrapped"
      refute log =~ "fixture-"

      assert Repo.one!(
               from s in Apiary.Secrets.InstanceSecret,
                 where: s.adapter_id == ^ctx.adapter.id,
                 select: s.revision
             ) == 1
    end

    test "has no value when a stored secret cannot be decrypted, and the delivery is 503", ctx do
      pt = plaintext([{"signing-key", @signing_key}])
      assert send_post(ctx, upload(ctx, pt)).status == 204

      # The value's row, changed: it no longer decrypts.
      {1, _} =
        Repo.update_all(Apiary.Secrets.InstanceSecretValue,
          set: [nonce: :crypto.strong_rand_bytes(12)]
        )

      log =
        capture_log([level: :debug], fn ->
          assert json_response(send_get(ctx), 503) == %{"error" => "unavailable"}
        end)

      assert log =~ "cannot be decrypted adapter_id=#{ctx.adapter.public_id}"
      refute log =~ "fixture-"
      assert seal_entries(ctx.adapter) == []
    end
  end

  # The contract's invalid uploads of the same names, `contracts/integration/v1/fixtures/
  # adapter/invalid/` at the commit in `.integration-contract-ref`, which Core does not
  # vendor, made fresh for this adapter.
  defp invalid_upload(ctx, "adapter-secrets-value-in-clear") do
    body = upload(ctx, plaintext([]))
    put_in(body, ["sealed", "values"], [%{"name" => "signing-key", "value" => "in clear"}])
  end

  defp invalid_upload(ctx, "adapter-secrets-without-server-key") do
    body = upload(ctx, plaintext([]))
    update_in(body, ["sealed"], &Map.delete(&1, "server_key"))
  end

  describe "a key that fails a key check" do
    # A key of the adapter whose public key is one of the contract's published fixture
    # keys (seed bytes 161 to 192), which `Apiary.Contract.Ed25519.check_public_key/1`
    # refuses. Enrolment refuses such a key, so the row is written here directly, as
    # `Apiary.AccessKeysFixtures.installed_key_fixture/2` writes one.
    defp fixture_key(adapter) do
      seed = :binary.list_to_bin(Enum.to_list(161..192))
      {public, _secret} = :crypto.generate_key(:eddsa, :ed25519, seed)
      assert {:error, :fixture} = Ed25519.check_public_key(public)
      now = DateTime.utc_now()
      key_id = Apiary.AccessKeys.AccessKey.generate_key_id()
      code = Apiary.AccessKeys.EnrolmentCode.generate(:adapter)

      code_row =
        %Apiary.AccessKeys.EnrolmentCode{
          id: Ecto.UUID.generate(),
          node_id: adapter.id,
          code_sha256: Apiary.AccessKeys.EnrolmentCode.hash(code),
          expires_at: DateTime.add(now, 15, :minute),
          used_at: now,
          used_by_key_id: key_id,
          public_key: public
        }
        |> Ecto.Changeset.change()
        |> Apiary.AccessKeys.EnrolmentCode.put_integrity()
        |> Repo.insert!()

      key =
        %Apiary.AccessKeys.AccessKey{
          id: Ecto.UUID.generate(),
          node_id: adapter.id,
          key_id: key_id,
          public_key: public,
          arrived_by: :code,
          enrolment_code_id: code_row.id,
          received_at: now
        }
        |> Apiary.AccessKeys.AccessKey.insert_changeset(%{allow_secrets: false, label: "fixture"})
        |> Apiary.AccessKeys.AccessKey.put_integrity()
        |> Repo.insert!()

      Repo.insert!(%Apiary.AccessKeys.PublicKey{
        public_key: public,
        key_id: key_id,
        state: :current,
        received_at: now
      })

      {key, seed}
    end

    test "is a signed 503 for a delivery, with no entry", ctx do
      assert send_post(ctx, upload(ctx, plaintext([{"signing-key", "v"}]))).status == 204
      {key, seed} = fixture_key(ctx.adapter)

      conn = send_get(%{ctx | key: key, seed: seed})
      assert json_response(conn, 503) == %{"error" => "unavailable"}
      assert signed_answer?(conn)
      assert seal_entries(ctx.adapter) == []
    end
  end

  describe "a crypto failure along the whole path" do
    # The instance's log level is `info` (`config/prod.exs`); the test's process logs at
    # that level, whatever the suite's level is.
    defp capture_info(fun) do
      capture_log(fn ->
        Logger.put_process_level(self(), :info)

        try do
          fun.()
        after
          Logger.delete_process_level(self())
        end
      end)
    end

    # Every form of a byte string a log line could contain.
    defp forms(bytes) do
      [
        bytes,
        Base.encode16(bytes, case: :lower),
        Base.encode16(bytes),
        Base.encode64(bytes),
        Base.url_encode64(bytes, padding: false),
        inspect(bytes)
      ]
    end

    defp refute_in_log(log, secrets) do
      for secret <- secrets, form <- forms(secret), byte_size(form) >= 8 do
        refute String.contains?(log, form)
      end
    end

    test "logs no value, nonce or ciphertext, and each step answers as the code says", ctx do
      pt = plaintext([{"signing-key", @signing_key}, {"event-secret", @event_secret}])
      body = upload(ctx, pt)

      log =
        capture_info(fn ->
          # The upload opens and is stored.
          assert send_post(ctx, body).status == 204

          # An envelope whose ciphertext does not open: 400.
          broken =
            update_in(upload(ctx, pt), ["sealed", "ct"], &("AAAA" <> String.slice(&1, 4..-1//1)))

          assert json_response(send_post(ctx, broken), 400) == @invalid

          # The delivery seals the values.
          assert send_get(ctx).status == 200
        end)

      rows = Repo.all(InstanceSecretValue)
      assert length(rows) == 2

      envelope =
        for key <- ["enc", "ct"],
            do: Base.url_decode64!(body["sealed"][key], padding: false)

      secrets =
        [@signing_key, @event_secret] ++
          Enum.flat_map(rows, &[&1.nonce, &1.ciphertext]) ++ envelope

      refute_in_log(log, secrets)

      # The data key no longer unwraps: the upload and the delivery are 503, each with
      # the one line that contains the key's id.
      {1, _} =
        Repo.update_all(InstanceDataKey, set: [wrapped_key: :crypto.strong_rand_bytes(60)])

      log =
        capture_info(fn ->
          assert json_response(send_post(ctx, upload(ctx, pt)), 503) ==
                   %{"error" => "unavailable"}

          assert json_response(send_get(ctx, timestamp: SignedRequest.now() + 1), 503) ==
                   %{"error" => "unavailable"}
        end)

      assert log =~ "the instance's data key cannot be unwrapped key_id="
      refute_in_log(log, secrets)
    end

    test "a raise in the store or the read is a 503 whose log line has the exception's module alone",
         ctx do
      pt = plaintext([{"signing-key", @signing_key}])
      assert send_post(ctx, upload(ctx, pt)).status == 204
      [row] = Repo.all(InstanceSecretValue)

      # The values' table is renamed inside the test's transaction, which the sandbox
      # rolls back: every query of it raises `Postgrex.Error`.
      Repo.query!("ALTER TABLE instance_secret_values RENAME TO instance_secret_values_away")

      log =
        capture_info(fn ->
          conn = send_post(ctx, upload(ctx, plaintext([{"signing-key", "other"}])))
          assert json_response(conn, 503) == %{"error" => "unavailable"}

          conn = send_get(ctx)
          assert json_response(conn, 503) == %{"error" => "unavailable"}
        end)

      assert log =~ "an adapter's secrets could not be stored: Postgrex.Error"
      assert log =~ "an adapter's secrets could not be sealed: Postgrex.Error"
      refute_in_log(log, [@signing_key, "other", row.nonce, row.ciphertext])
    end
  end
end
