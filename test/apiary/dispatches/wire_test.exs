defmodule Apiary.Dispatches.WireTest do
  # The bodies a node pool's starter posts, read as the provisioner contract has them:
  # every request fixture vendored from the commit in
  # `test/fixtures/contract/provisioner/v1/.contract-ref`, valid and invalid, and each
  # field refused in turn, with members twice, integers written with a fraction, members
  # the schema does not define, and labels on a handover.
  use ExUnit.Case, async: true

  alias Apiary.Dispatches.Wire

  @contract Path.expand("../../fixtures/contract/provisioner/v1", __DIR__)
  @fixtures Path.join(@contract, "fixtures")

  # The request bodies and their readers; the answers' fixtures are the control plane's
  # to write, not to read.
  @readers %{
    "claim" => &Wire.claim/1,
    "dispatched" => &Wire.dispatched/1,
    "handover" => &Wire.handover/1,
    "release" => &Wire.release/1
  }

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!()

  defp read(reader, raw) when is_binary(raw) do
    with {:ok, body} <- Wire.decode(raw), do: reader.(body)
  end

  defp read(reader, body), do: read(reader, Jason.encode!(body))

  defp claim(body), do: read(&Wire.claim/1, body)
  defp dispatched(body), do: read(&Wire.dispatched/1, body)
  defp handover(body), do: read(&Wire.handover/1, body)
  defp release(body), do: read(&Wire.release/1, body)

  @claim %{"version" => 1, "time" => "2026-10-15T12:00:00Z", "wait_seconds" => 10}
  @external %{
    "type" => "example-ci",
    "ref" => "run-8812",
    "url" => "https://ci.example.com/acme/shop/runs/8812"
  }
  @dispatched %{"version" => 1, "time" => "2026-10-15T12:00:20Z", "external" => @external}
  @handover %{"version" => 1, "time" => "2026-10-15T12:01:00Z"}
  @release %{
    "version" => 1,
    "time" => "2026-10-15T12:02:00Z",
    "reason" => "The job could not start.",
    "retry" => false
  }

  test "the vendored contract is the commit its ref names" do
    assert File.read!(Path.join(@contract, ".contract-ref")) ==
             "b92cafbeaa4927943b914112449e60491b4930d3\n"
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
          String.starts_with?(path, ["claim-answer/", "handover-answer/"]) or
            (String.starts_with?(path, "invalid/") and String.contains?(path, "-answer-")),
          do: path

    refusals = for "refusal/" <> _ = path <- all, do: path

    assert Enum.sort(requests ++ invalid_requests ++ answers ++ refusals) == Enum.sort(all)
    assert length(requests) == 6
    assert length(invalid_requests) == 4
    assert length(answers) == 8
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

    assert Enum.sort(codes) == ["handed_over", "no_gateway", "unavailable"]
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
               "handover/handover.json",
               "release/retry.json"
             ]
    end

    test "the claims are read to their values" do
      assert claim(fixture("claim/one-pool.json")) ==
               {:ok,
                %{time: ~U[2026-10-15 12:00:00Z], pool_id: "np_f1xt0re000000000", wait_seconds: 0}}

      assert claim(fixture("claim/without-pool-id.json")) ==
               {:ok, %{time: ~U[2026-10-15 12:00:00Z], pool_id: nil, wait_seconds: 25}}
    end

    test "the dispatched, the handover and the release are read to their values" do
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

      assert handover(fixture("handover/handover.json")) ==
               {:ok, %{time: ~U[2026-10-15 12:01:00Z]}}

      assert release(fixture("release/retry.json")) ==
               {:ok,
                %{
                  time: ~U[2026-10-15 12:02:00Z],
                  reason: "The job could not start: no runner was free.",
                  retry: true
                }}
    end

    test "every invalid request fixture is refused" do
      refused =
        for path <- Path.wildcard(Path.join([@fixtures, "invalid", "*.json"])),
            name = Path.basename(path),
            # An answer's fixture is the starter's to refuse.
            not String.contains?(name, "-answer-") do
          [kind | _] = String.split(name, "-", parts: 2)
          assert read(Map.fetch!(@readers, kind), File.read!(path)) == :error, name
          name
        end

      assert Enum.sort(refused) == [
               "claim-pool-id-node.json",
               "claim-undefined-member.json",
               "claim-wait-seconds-26.json",
               "dispatched-external-type-upper-case.json"
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
            {@handover, &Wire.handover/1},
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
      assert handover(Map.put(@handover, "run_id", "x")) == :error
      assert release(Map.put(@release, "run_id", "x")) == :error
    end

    test "a version other than 1, or a time not in whole seconds of UTC" do
      for {body, reader} <- [
            {@claim, &Wire.claim/1},
            {@dispatched, &Wire.dispatched/1},
            {@handover, &Wire.handover/1},
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
            &Map.put(&1, "time", 1_792_065_600)
          ] do
        changed = change.(body)
        assert read(reader, changed) == :error, inspect(changed)
      end
    end
  end

  describe "a handover" do
    test "carrying labels, or anything else a registration would carry, is refused" do
      assert handover(Map.put(@handover, "labels", ["linux"])) == :error
      assert handover(Map.put(@handover, "labels", [])) == :error
      assert handover(Map.put(@handover, "labels", %{})) == :error

      assert handover(Map.put(@handover, "run_id", "0192f0c1-7d4e-7a2b-8c3d-4e5f6a7b8c9d")) ==
               :error

      assert handover(Map.put(@handover, "about", "x")) == :error
      assert {:ok, _} = handover(@handover)
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
            Map.put(@external, "ref", ""),
            Map.put(@external, "ref", String.duplicate("r", 201)),
            Map.put(@external, "ref", 8812),
            Map.put(@external, "url", "http://ci.example.com/runs/8812"),
            Map.put(@external, "url", "https://user@ci.example.com/runs/8812"),
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
    test "refuses a reason that is not 1 to 200 characters, and a retry that is not a boolean" do
      for change <- [
            &Map.put(&1, "reason", ""),
            &Map.put(&1, "reason", String.duplicate("r", 201)),
            &Map.put(&1, "reason", nil),
            &Map.put(&1, "reason", 1),
            &Map.delete(&1, "reason"),
            &Map.put(&1, "retry", "true"),
            &Map.put(&1, "retry", 1),
            &Map.put(&1, "retry", nil),
            &Map.delete(&1, "retry")
          ] do
        changed = change.(@release)
        assert release(changed) == :error, inspect(changed)
      end
    end

    test "counts a reason's characters, not its bytes" do
      reason = String.duplicate("é", 200)

      assert {:ok, %{reason: ^reason, retry: false}} =
               release(Map.put(@release, "reason", reason))
    end
  end
end
