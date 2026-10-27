defmodule Apiary.Dispatches.WireTest do
  # The bodies a node pool's starter posts, read as the provisioner contract has them:
  # every request fixture vendored from the commit in
  # `test/fixtures/contract/provisioner/v1/.contract-ref`, valid and invalid, and each
  # field refused in turn, with members twice, integers written with a fraction, and
  # members the schema does not define.
  use ExUnit.Case, async: true

  alias Apiary.Dispatches.Wire

  @vendored Path.expand("../../fixtures/contract", __DIR__)
  @contract Path.join(@vendored, "provisioner/v1")
  @fixtures Path.join(@contract, "fixtures")
  @base "https://qory.dev/contracts/"

  # The vendored schemas, by their URL under the contracts' base: the provisioner
  # contract's, the run contract's documents under `run/v1/`, and the integration
  # contract's they refer to under `integration/v1/`; and Forager's, which the documents'
  # `run_settings` refers to, from Forager's contract directory
  # (`Apiary.ContractFixtures.contract_dir/0`), so a test that builds the documents'
  # schema is tagged `:contract`. Nothing is fetched.
  defmodule Resolver do
    @moduledoc false
    @behaviour JSV.Resolver

    @base "https://qory.dev/contracts/"

    @impl JSV.Resolver
    def resolve(@base <> path, roots) do
      Enum.find_value(roots, {:error, {:not_vendored, path}}, fn root ->
        file = Path.expand(path, root)

        with true <- String.starts_with?(file, root <> "/"),
             {:ok, body} <- File.read(file),
             {:ok, schema} <- Jason.decode(body) do
          {:ok, schema}
        else
          _ -> nil
        end
      end)
    end

    def resolve(url, _roots), do: {:error, {:not_vendored, url}}
  end

  # The schema a fixture is held to: its directory's, or, for one under `invalid/`, the
  # schema its name starts with, the longest that matches.
  @schemas ~w(claim-answer claim dispatched release machine-log refusal)

  defp schema_of("invalid/" <> name),
    do: Enum.find(@schemas, &String.starts_with?(name, &1 <> "-"))

  defp schema_of(path), do: path |> Path.split() |> hd()

  defp validator(schema, contract \\ "provisioner/v1") do
    JSV.build!(%{"$ref" => @base <> "#{contract}/#{schema}.schema.json"},
      resolver: {Resolver, [@vendored | forager()]},
      formats: true
    )
  end

  # The directory of Forager's contracts, when its contract directory is there.
  defp forager do
    case Apiary.ContractFixtures.contract_dir() do
      nil -> []
      dir -> [Path.expand("../..", dir)]
    end
  end

  defp valid?(schema, document), do: match?({:ok, _}, JSV.validate(document, validator(schema)))

  # The request bodies and their readers; the answers' fixtures are the control plane's
  # to write, not to read.
  @readers %{
    "claim" => &Wire.claim/1,
    "dispatched" => &Wire.dispatched/1,
    "release" => &Wire.release/1,
    "machine-log" => &Wire.machine_log/1
  }

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!()

  defp read(reader, raw) when is_binary(raw) do
    with {:ok, body} <- Wire.decode(raw), do: reader.(body)
  end

  defp read(reader, body), do: read(reader, Jason.encode!(body))

  defp claim(body), do: read(&Wire.claim/1, body)
  defp dispatched(body), do: read(&Wire.dispatched/1, body)
  defp release(body), do: read(&Wire.release/1, body)
  defp machine_log(body), do: read(&Wire.machine_log/1, body)

  @claim %{"version" => 1, "time" => "2026-10-15T12:00:00Z", "wait_seconds" => 10}
  @external %{
    "type" => "example-ci",
    "ref" => "run-8812",
    "url" => "https://ci.example.com/acme/shop/runs/8812"
  }
  @dispatched %{"version" => 1, "time" => "2026-10-15T12:00:20Z", "external" => @external}
  @release %{
    "version" => 1,
    "time" => "2026-10-15T12:02:00Z",
    "reason" => "The job could not start."
  }
  test "the vendored contracts are the commits their refs name" do
    for {dir, ref} <- [
          {"provisioner/v1", "1774020bb474b73913e8a9f0245bd466709e3d35"},
          {"run/v1", "e8272d526cbbcfcf416dc78c0a25c7079cb0f9f0"},
          {"integration/v1", "24f1125680838387abed1d16c7dbeac198b27994"},
          {"explore/v1", "dd274020be2ec6d678e13bd15401a6aceaba8bd7"}
        ] do
      assert File.read!(Path.join([@vendored, dir, ".contract-ref"])) == ref <> "\n", dir
    end
  end

  @tag :contract
  test "every fixture is valid under its vendored schema, or invalid under it as its directory says" do
    for path <- Path.wildcard(Path.join(@fixtures, "**/*.json")) do
      relative = Path.relative_to(path, @fixtures)
      schema = schema_of(relative)
      assert schema in @schemas, relative
      expected = not String.starts_with?(relative, "invalid/")
      assert valid?(schema, Jason.decode!(File.read!(path))) == expected, relative
    end
  end

  @tag :contract
  test "a work item's url in a run's documents is https, or http to a loopback address alone" do
    documents = Path.join(@vendored, "run/v1/fixtures")
    read = &(documents |> Path.join(&1) |> File.read!() |> Jason.decode!())
    valid? = &match?({:ok, _}, JSV.validate(&1, validator("documents", "run/v1")))

    loopback = read.("documents/explore-loopback.json")
    assert loopback["work_item"]["url"] == "http://127.0.0.1:8080/work-items/wi_8Kx2mQ4vT9"
    assert valid?.(loopback)

    http = read.("invalid/documents-work-item-url-http.json")
    assert http["work_item"]["url"] == "http://control.example.com/work-items/wi_8Kx2mQ4vT9"
    refute valid?.(http)

    for url <- [
          "http://localhost/work-items/wi_8Kx2mQ4vT9",
          "http://[::1]:4000/work-items/wi_8Kx2mQ4vT9",
          "https://control.example.com/work-items/wi_8Kx2mQ4vT9"
        ] do
      assert valid?.(put_in(loopback, ["work_item", "url"], url)), url
    end

    for url <- [
          "http://control.example.com/work-items/wi_8Kx2mQ4vT9",
          "http://127.0.0.2/work-items/wi_8Kx2mQ4vT9",
          "ftp://127.0.0.1/work-items/wi_8Kx2mQ4vT9"
        ] do
      refute valid?.(put_in(loopback, ["work_item", "url"], url)), url
    end
  end

  test "every fixture is a request read here, an answer, or a refusal" do
    all =
      @fixtures
      |> Path.join("**/*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, @fixtures))

    requests =
      for path <- all,
          [kind, _name] <- [Path.split(path)],
          Map.has_key?(@readers, kind),
          do: path

    invalid_requests =
      for "invalid/" <> name = path <- all, not String.contains?(name, "-answer-"), do: path

    answers =
      for path <- all,
          String.starts_with?(path, "claim-answer/") or
            (String.starts_with?(path, "invalid/") and String.contains?(path, "-answer-")),
          do: path

    refusals = for "refusal/" <> _ = path <- all, do: path

    assert Enum.sort(requests ++ invalid_requests ++ answers ++ refusals) == Enum.sort(all)

    assert length(requests) == 7
    assert length(invalid_requests) == 11
    assert length(answers) == 16
    assert length(refusals) == 3
  end

  test "each refusal fixture is a code, written as the control plane writes a refusal" do
    codes =
      for path <- Path.wildcard(Path.join([@fixtures, "refusal", "*.json"])) do
        assert {:ok, %{"error" => code} = refusal} = Wire.decode(File.read!(path)), path
        assert map_size(refusal) == 1
        assert Regex.match?(~r/\A[a-z_]{1,64}\z/, code)
        assert Jason.decode!(Jason.encode!(%{error: code})) == refusal
        code
      end

    assert Enum.sort(codes) == ["machine_exists", "machine_log_exists", "no_gateway"]
  end

  describe "the contract's fixtures" do
    test "every valid request fixture is read as written" do
      read =
        for {kind, reader} <- @readers,
            path <- Path.wildcard(Path.join([@fixtures, kind, "*.json"])) do
          assert {:ok, _} = read(reader, File.read!(path)), path
          Path.relative_to(path, @fixtures)
        end

      assert Enum.sort(read) == [
               "claim/one-pool.json",
               "claim/without-pool-id.json",
               "dispatched/with-external.json",
               "dispatched/without-external.json",
               "machine-log/truncated.json",
               "machine-log/whole.json",
               "release/no-capacity.json"
             ]
    end

    test "the claims are read to their values" do
      assert claim(fixture("claim/one-pool.json")) ==
               {:ok,
                %{time: ~U[2026-10-15 12:00:00Z], pool_id: "np_f1xt0re000000000", wait_seconds: 0}}

      assert claim(fixture("claim/without-pool-id.json")) ==
               {:ok, %{time: ~U[2026-10-15 12:00:00Z], pool_id: nil, wait_seconds: 25}}
    end

    test "the dispatched and the release are read to their values" do
      assert dispatched(fixture("dispatched/with-external.json")) ==
               {:ok,
                %{
                  time: ~U[2026-10-15 12:00:20Z],
                  external: %{
                    type: "example-ci",
                    ref: "run-8812",
                    url: "https://ci.example.com/acme/shop/runs/8812"
                  }
                }}

      assert dispatched(fixture("dispatched/without-external.json")) ==
               {:ok, %{time: ~U[2026-10-15 12:00:20Z], external: nil}}

      assert release(fixture("release/no-capacity.json")) ==
               {:ok,
                %{
                  time: ~U[2026-10-15 12:02:00Z],
                  reason: "The machine could not be created: the vendor had no capacity."
                }}
    end

    test "every invalid request fixture is refused" do
      refused =
        for path <- Path.wildcard(Path.join([@fixtures, "invalid", "*.json"])),
            name = Path.basename(path),
            # An answer's fixture is the starter's to refuse.
            not String.contains?(name, "-answer-") do
          kind = Enum.find(Map.keys(@readers), &String.starts_with?(name, &1 <> "-"))
          assert read(Map.fetch!(@readers, kind), File.read!(path)) == :error, name
          name
        end

      assert Enum.sort(refused) == [
               "claim-pool-id-node.json",
               "claim-undefined-member.json",
               "claim-wait-seconds-26.json",
               "dispatched-external-ref-nul.json",
               "dispatched-external-type-upper-case.json",
               "machine-log-log-nul.json",
               "machine-log-undefined-member.json",
               "machine-log-version-2.json",
               "machine-log-without-log.json",
               "release-reason-nul.json",
               "release-with-retry.json"
             ]
    end
  end

  describe "what every body refuses" do
    test "a body that is no JSON object, or repeats a member at any depth" do
      for {_kind, reader} <- @readers,
          raw <- ["", "null", "[]", "1", ~s("text"), "not json", ~s({"version":1,"version":1})] do
        assert read(reader, raw) == :error, raw
      end

      raw = Jason.encode!(@dispatched)
      nested = String.replace(raw, ~s("type":"example-ci"), ~s("type":"example-ci","type":"x"))
      assert nested != raw
      assert dispatched(nested) == :error
    end

    test "an integer written with a fraction or an exponent" do
      assert claim(String.replace(Jason.encode!(@claim), ~s("version":1), ~s("version":1.0))) ==
               :error

      assert claim(
               String.replace(
                 Jason.encode!(@claim),
                 ~s("wait_seconds":10),
                 ~s("wait_seconds":10.0)
               )
             ) == :error

      assert claim(
               String.replace(
                 Jason.encode!(@claim),
                 ~s("wait_seconds":10),
                 ~s("wait_seconds":1e1)
               )
             ) == :error

      for {body, reader} <- [
            {@dispatched, &Wire.dispatched/1},
            {@release, &Wire.release/1}
          ] do
        raw = String.replace(Jason.encode!(body), ~s("version":1), ~s("version":1.0))
        assert read(reader, raw) == :error, raw
      end
    end

    test "a member the schema does not define, at any depth" do
      assert claim(Map.put(@claim, "workspace", "ws_f1xt0re000000000")) == :error
      assert dispatched(Map.put(@dispatched, "run_id", "x")) == :error
      assert dispatched(put_in(@dispatched, ["external", "name"], "CI")) == :error
      assert release(Map.put(@release, "run_id", "x")) == :error
      assert release(Map.put(@release, "retry", true)) == :error
    end

    test "a version other than 1, or a time not in whole seconds of UTC" do
      for {body, reader} <- [
            {@claim, &Wire.claim/1},
            {@dispatched, &Wire.dispatched/1},
            {@release, &Wire.release/1}
          ],
          change <- [
            &Map.put(&1, "version", 2),
            &Map.put(&1, "version", "1"),
            &Map.delete(&1, "version"),
            &Map.delete(&1, "time"),
            &Map.put(&1, "time", nil),
            &Map.put(&1, "time", "2026-10-15T12:00:00.5Z"),
            &Map.put(&1, "time", "2026-10-15T12:00:00+00:00"),
            &Map.put(&1, "time", "2026-10-15 12:00:00Z"),
            &Map.put(&1, "time", "2026-10-15T12:00:00\u0000"),
            &Map.put(&1, "time", 1_792_065_600)
          ] do
        changed = change.(body)
        assert read(reader, changed) == :error, inspect(changed)
      end
    end
  end

  describe "bounded first" do
    # The bound the adapter wire's test holds a refused body to
    # (`test/apiary/sources/wire_test.exs`), as these bodies are decoded as an adapter's
    # are. Generous for a shared machine: the costliest of them, many members or deep
    # nesting, is refused in about a tenth of a second on an idle machine and has taken
    # over half a second on a shared one.
    @quick_ms 1000

    defp quick(fun) do
      {microseconds, result} = :timer.tc(fun)
      assert div(microseconds, 1000) < @quick_ms, "took #{div(microseconds, 1000)} ms"
      result
    end

    test "a raw body one byte over 1 MiB is refused undecoded, at once" do
      assert Wire.max_bytes() == 1024 * 1024
      at_limit = Jason.encode!(@claim) <> String.duplicate(" ", 1024 * 1024)
      at_limit = binary_part(at_limit, 0, 1024 * 1024)
      over = at_limit <> " "

      for {_kind, reader} <- @readers do
        assert quick(fn -> read(reader, over) end) == :error
      end

      assert {:ok, _} = Wire.decode(Jason.encode!(@claim) <> String.duplicate(" ", 1024))
    end

    test "a crafted body of up to 1 MiB is refused quickly, whatever its shape" do
      mib = 1024 * 1024
      depth = div(mib, 2) - 1
      objects = div(mib, 6) - 1

      bodies = [
        String.duplicate("[", depth) <> String.duplicate("]", depth),
        String.duplicate(~s({"a":), objects) <> "1" <> String.duplicate("}", objects),
        "{" <> Enum.map_join(1..80_000, ",", &~s("k#{&1}":1)) <> "}",
        ~s({"version":1,"labels":[) <> Enum.map_join(1..300_000, ",", fn _ -> "1" end) <> "]}",
        ~s({"a":[) <> Enum.map_join(1..60_000, ",", fn _ -> ~s({"b":1,"b":1}) end) <> "]}",
        Jason.encode!(Map.put(@release, "reason", String.duplicate("\u00e9", 170_000)))
      ]

      for body <- bodies, {kind, reader} <- @readers do
        assert byte_size(body) <= mib
        assert quick(fn -> read(reader, body) end) == :error, kind
      end
    end

    test "an object of more members than its schema defines is refused before they are compared" do
      many = Map.new(1..10_000, &{"k#{&1}", 1})

      assert quick(fn -> claim(Map.merge(@claim, many)) end) == :error
      assert quick(fn -> dispatched(put_in(@dispatched, ["external"], many)) end) == :error
      assert quick(fn -> release(Map.merge(@release, many)) end) == :error
    end

    test "a string just over its bound in bytes is refused, and one at it is read" do
      four_bytes = "\u{1F600}"
      assert byte_size(four_bytes) == 4

      at_bound = String.duplicate(four_bytes, 200)
      over = String.duplicate(four_bytes, 201)

      assert {:ok, %{reason: ^at_bound}} = release(Map.put(@release, "reason", at_bound))
      assert quick(fn -> release(Map.put(@release, "reason", over)) end) == :error

      assert {:ok, %{external: %{ref: ^at_bound}}} =
               dispatched(put_in(@dispatched, ["external", "ref"], at_bound))

      assert dispatched(put_in(@dispatched, ["external", "ref"], over)) == :error

      # 200 characters of one byte each are 200 bytes: the count still holds them to 200.
      assert release(Map.put(@release, "reason", String.duplicate("r", 201))) == :error

      assert claim(Map.put(@claim, "pool_id", "np_0123456789abcdef0")) == :error
      assert claim(Map.put(@claim, "time", "2026-10-15T12:00:00Z ")) == :error
      assert claim(Map.put(@claim, "time", String.duplicate("2", 100_000))) == :error

      assert dispatched(put_in(@dispatched, ["external", "type"], String.duplicate("a", 41))) ==
               :error
    end
  end

  describe "a claim" do
    test "takes a wait from 0 to 25 seconds, and a pool's id when given" do
      for wait <- [0, 1, 25] do
        assert {:ok, %{wait_seconds: ^wait}} = claim(Map.put(@claim, "wait_seconds", wait))
      end

      assert {:ok, %{pool_id: "np_0123456789abcdef"}} =
               claim(Map.put(@claim, "pool_id", "np_0123456789abcdef"))
    end

    test "refuses a wait outside 0 to 25, missing or not an integer" do
      for wait <- [-1, 26, "10", nil, true] do
        assert claim(Map.put(@claim, "wait_seconds", wait)) == :error, inspect(wait)
      end

      assert claim(Map.delete(@claim, "wait_seconds")) == :error
    end

    test "refuses a pool id that is not a node pool's" do
      for pool_id <- [
            nil,
            "",
            "np_",
            "np_0123456789ABCDEF",
            "np_0123456789abcdeu",
            "np_0123456789abcdef0",
            "nd_0123456789abcdef",
            "np_0123456789abcdef\n",
            "np_0123456789abcde\u0000",
            1
          ] do
        assert claim(Map.put(@claim, "pool_id", pool_id)) == :error, inspect(pool_id)
      end
    end
  end

  describe "a dispatched" do
    test "refuses an external that is not exactly type, ref and url, each as the contract has it" do
      for external <- [
            nil,
            [],
            "example-ci",
            Map.delete(@external, "type"),
            Map.delete(@external, "ref"),
            Map.delete(@external, "url"),
            Map.put(@external, "type", "Example-CI"),
            Map.put(@external, "type", "1ci"),
            Map.put(@external, "type", ""),
            Map.put(@external, "type", String.duplicate("a", 41)),
            Map.put(@external, "type", "ci_system"),
            Map.put(@external, "type", "example\u0000ci"),
            Map.put(@external, "ref", ""),
            Map.put(@external, "ref", String.duplicate("r", 201)),
            Map.put(@external, "ref", 8812),
            Map.put(@external, "ref", "run\u00008812"),
            Map.put(@external, "ref", "\u0000"),
            Map.put(@external, "url", "http://ci.example.com/runs/8812"),
            Map.put(@external, "url", "https://user@ci.example.com/runs/8812"),
            Map.put(@external, "url", "https://ci.example.com/runs/\u00008812"),
            Map.put(@external, "url", "https://ci.example.com/" <> String.duplicate("a", 2048))
          ] do
        assert dispatched(Map.put(@dispatched, "external", external)) == :error,
               inspect(external)
      end
    end

    test "takes a job system and a ref at their limits" do
      external = %{
        @external
        | "type" => "a" <> String.duplicate("b- 9", 9) <> "xyz",
          "ref" => String.duplicate("é", 200)
      }

      assert String.length(external["type"]) == 40

      assert dispatched(Map.put(@dispatched, "external", external)) ==
               {:ok,
                %{
                  time: ~U[2026-10-15 12:00:20Z],
                  external: %{type: external["type"], ref: external["ref"], url: external["url"]}
                }}
    end
  end

  describe "a release" do
    test "refuses a reason that is not 1 to 200 characters, and any retry" do
      for change <- [
            &Map.put(&1, "reason", ""),
            &Map.put(&1, "reason", String.duplicate("r", 201)),
            &Map.put(&1, "reason", nil),
            &Map.put(&1, "reason", 1),
            &Map.put(&1, "reason", "The job\u0000could not start."),
            &Map.put(&1, "reason", "\u0000"),
            &Map.delete(&1, "reason"),
            &Map.put(&1, "retry", true),
            &Map.put(&1, "retry", false)
          ] do
        changed = change.(@release)
        assert release(changed) == :error, inspect(changed)
      end
    end

    test "refuses a reason or a ref that is not valid UTF-8" do
      invalid = "run-" <> <<0xFF>>

      assert Wire.release(Map.put(@release, "reason", invalid)) == :error
      external = Map.put(@external, "ref", invalid)
      assert Wire.dispatched(Map.put(@dispatched, "external", external)) == :error
    end

    test "counts a reason's characters, not its bytes" do
      reason = String.duplicate("é", 200)

      assert {:ok, %{reason: ^reason}} =
               release(Map.put(@release, "reason", reason))
    end
  end

  # The contract's `machine-log/whole.json`; the changes each test makes are put over it.
  @machine_log @fixtures |> Path.join("machine-log/whole.json") |> File.read!() |> Jason.decode!()

  describe "a machine log" do
    test "is read to its values, truncated false when absent" do
      assert {:ok, %{log: log, truncated: false, time: ~U[2026-10-15 12:10:00Z]}} =
               machine_log(@machine_log)

      assert log == @machine_log["log"]

      assert machine_log(fixture("machine-log/truncated.json")) ==
               {:ok,
                %{
                  time: ~U[2026-10-15 12:10:00Z],
                  log:
                    "2026-10-15T12:09:12Z job ended: exit 0\n2026-10-15T12:09:15Z machine stopped\n",
                  truncated: true
                }}

      assert {:ok, %{truncated: true}} = machine_log(Map.put(@machine_log, "truncated", true))
      assert {:ok, %{truncated: false}} = machine_log(Map.put(@machine_log, "truncated", false))
      assert {:ok, %{log: ""}} = machine_log(Map.put(@machine_log, "log", ""))
    end

    test "takes a log of 786,432 characters and refuses one of 786,433" do
      at_bound = String.duplicate("a", 786_432)
      assert {:ok, %{log: ^at_bound}} = machine_log(Map.put(@machine_log, "log", at_bound))

      assert machine_log(Map.put(@machine_log, "log", String.duplicate("a", 786_433))) ==
               :error

      # 786,432 characters in 786,433 bytes: the bound is in characters.
      wide = String.duplicate("a", 786_431) <> "é"
      assert {String.length(wide), byte_size(wide)} == {786_432, 786_433}
      assert {:ok, %{log: ^wide}} = machine_log(Map.put(@machine_log, "log", wide))
      assert machine_log(Map.put(@machine_log, "log", wide <> "a")) == :error
    end

    test "refuses each body the contract's invalid fixtures have, and every other wrong value" do
      for body <- [
            Map.put(@machine_log, "version", 2),
            Map.put(@machine_log, "gzip", true),
            Map.delete(@machine_log, "log"),
            Map.put(@machine_log, "log", "machine created\u0000\n"),
            Map.delete(@machine_log, "time"),
            Map.delete(@machine_log, "version"),
            Map.put(@machine_log, "log", nil),
            Map.put(@machine_log, "log", 1),
            Map.put(@machine_log, "truncated", "true"),
            Map.put(@machine_log, "truncated", nil),
            Map.put(@machine_log, "time", "2026-10-15T12:10:00.5Z")
          ] do
        assert machine_log(body) == :error, inspect(body)
      end

      assert machine_log(~s({"version":1,"time":"2026-10-15T12:10:00Z","log":"a","log":"b"})) ==
               :error

      assert machine_log(~s({"version":1.0,"time":"2026-10-15T12:10:00Z","log":"a"})) ==
               :error
    end
  end
end
