defmodule Apiary.Policy.AllowFirstTest do
  @moduledoc """
  The document's `egress.allow_first` against Forager's contract at the commit in
  `.forager-contract-ref`: the vendored policy schema and fixtures are that commit's
  bytes, a rendered document has the shape of the contract's fixture, the schema check
  refuses the contract's invalid fixtures, and a run whose `run.policy_applied` contains
  `allow_first` is read and compared as in force.
  """
  use Apiary.DataCase, async: true

  import Apiary.ConnectionsFixtures, only: [ready_release!: 3]
  import Apiary.DescriptionFixtures, only: [tracker_description: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{Connections, ContractFixtures, Policy}
  alias Apiary.Policy.{Error, Render, Resolution, Rule, Schema}
  alias Apiary.Runs.{Projector, Record, Run}

  @root Path.expand("../../..", __DIR__)

  # The policy files vendored from qoryai/forager at the commit in `.forager-contract-ref`,
  # by their SHA-256 there.
  @forager_ref "072c240d154ceacd8fd1055cb9a63152c724f09f"
  @vendored_sha256 %{
    "priv/contract/policy.schema.json" =>
      "13da5724b2a6760420ca0c4236ac894edcafb87645d8e2569f3219b692cd03e5",
    "test/fixtures/forager-contract/policy/observe-allow-first.yaml" =>
      "ee3bf34b1ad1c0232a64ec75e15c18ce28d49331642179135aed2e412aebb42a",
    "test/fixtures/forager-contract/invalid/policy-allow-first-pattern.yaml" =>
      "30ea3596f7f24ec671350c4aeb14cc864a46ff69455e7c74dfdd52a863fabb08",
    "test/fixtures/forager-contract/invalid/policy-allow-first-too-many.yaml" =>
      "4a82b096cd5495a897f78ca231b2e68448f333d07d0f560de348abce45b7fbe9"
  }

  @fixtures Path.join(@root, "test/fixtures/forager-contract")
  @connection %{id: Ecto.UUID.generate(), public_id: "con_tracker", name: "acme-tracker"}

  # A policy fixture of the contract, read as YAML. The fixtures read here have comment
  # lines, `key: value` pairs, `key:` with a block two spaces deeper, and lists of
  # scalars; this reader takes that and nothing more.
  defp fixture!(path) do
    {document, []} =
      @fixtures
      |> Path.join(path)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
      |> Enum.map(&{div(byte_size(&1) - byte_size(String.trim_leading(&1)), 2), String.trim(&1)})
      |> block(0)

    document
  end

  defp block([{depth, "- " <> _item} | _rest] = lines, depth), do: list(lines, depth, [])
  defp block(lines, depth), do: object(lines, depth, %{})

  defp list([{depth, "- " <> item} | rest], depth, acc),
    do: list(rest, depth, [scalar(item) | acc])

  defp list(rest, _depth, acc), do: {Enum.reverse(acc), rest}

  defp object([{depth, line} | rest], depth, acc) do
    [key, value] = String.split(line, ":", parts: 2)

    case String.trim(value) do
      "" ->
        {inner, rest} = block(rest, depth + 1)
        object(rest, depth, Map.put(acc, key, inner))

      value ->
        object(rest, depth, Map.put(acc, key, scalar(value)))
    end
  end

  defp object(rest, _depth, acc), do: {acc, rest}

  defp scalar("\"" <> _rest = quoted), do: Jason.decode!(quoted)

  defp scalar(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _other -> value
    end
  end

  # A policy as the run configuration that contains it.
  defp configuration(policy), do: Jason.encode!(%{"version" => 1, "security_policy" => policy})

  describe "the vendored policy files" do
    test "are the bytes of the pinned commit" do
      assert ContractFixtures.pinned_ref() == @forager_ref

      for {path, sha256} <- @vendored_sha256 do
        assert path in ContractFixtures.vendored(), path
        bytes = File.read!(Path.join(@root, path))
        assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == sha256, path
      end
    end
  end

  describe "the contract's fixtures" do
    test "a rendered document has the shape of observe-allow-first.yaml" do
      fixture = fixture!("policy/observe-allow-first.yaml")

      assert fixture == %{
               "version" => 1,
               "egress" => %{
                 "mode" => "observe",
                 "allow_first" => ["api.example", "10.0.0.5"],
                 "deny" => ["*.example"]
               }
             }

      assert Schema.validate(configuration(fixture)) == :ok

      {:ok, effective} =
        Resolution.resolve(
          "observe",
          [%Rule{kind: "host", action: "deny", host: "*.example", locked: false}],
          [],
          nil,
          nil,
          for(host <- ["api.example", "10.0.0.5"], do: %{host: host, connection: @connection})
        )

      assert {:ok, document, ["10.0.0.5", "api.example"]} = Render.render(effective)
      assert Policy.valid_document(document) == :ok

      # The render always writes `allow`, and sorts `allow_first`.
      assert Jason.decode!(document)["security_policy"] ==
               put_in(fixture, ["egress", "allow"], [])
               |> update_in(["egress", "allow_first"], &Enum.sort/1)

      assert document ==
               ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe",) <>
                 ~s("allow":[],"allow_first":["10.0.0.5","api.example"],"deny":["*.example"]}}})
    end

    test "the schema check refuses the invalid ones" do
      for {path, refused} <- [
            {"invalid/policy-allow-first-pattern.yaml", ["*.example"]},
            {"invalid/policy-allow-first-too-many.yaml", for(n <- 0..64, do: "host-#{n}.example")}
          ] do
        fixture = fixture!(path)
        assert fixture["egress"]["allow_first"] == refused, path
        assert {:error, _reason} = Schema.validate(configuration(fixture)), path

        assert capture_log(fn ->
                 assert {:error, %Error{reason: :invalid_document, message: message}} =
                          Policy.valid_document(configuration(fixture))

                 assert message ==
                          "The change was not made: the run configuration it renders is not one Forager's contract accepts."
               end) =~ "refused by the contract's schema"
      end
    end
  end

  describe "a run whose run.policy_applied contains allow_first" do
    @describetag needs: :secrets

    setup do
      %{scope: scope} = sign_up_fixture()
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})

      release =
        ready_release!(
          scope,
          tracker_description(%{"egress_hosts" => ["api.example.com"]}),
          "codeberg.org/acme/tracker"
        )

      {:ok, _connection} = Connections.create_integration(scope, release.id, %{})
      {:ok, configuration} = Policy.current_configuration(scope, nil)
      %{scope: scope, configuration: configuration}
    end

    test "is read, and counts as in force when its digest is the one in force", ctx do
      %{scope: scope, configuration: configuration} = ctx
      digest = configuration.digest

      assert Jason.decode!(configuration.document)["security_policy"]["egress"]["allow_first"] ==
               ["api.example.com"]

      run = run_fixture(scope, %{reported_run_configuration_digest: digest})

      events_fixture(run, [
        {1, "run.started", started_data()},
        {2, "run.policy_applied",
         %{
           "mode" => "observe",
           "allow" => ["docs.example.com"],
           "allow_first" => ["api.example.com"],
           "source" => "fetched",
           "digest" => "sha256=" <> String.duplicate("a", 64),
           "run_configuration" => digest
         }}
      ])

      {:ok, run} = Projector.project(run)
      run = Repo.get!(Run, run.id)

      assert %{
               allow: ["docs.example.com"],
               allow_count: 1,
               allow_first: ["api.example.com"],
               allow_first_count: 1
             } = Record.policy(scope, run)

      assert Policy.digests(scope, run) ==
               %{in_force: digest, reported: digest, applied: digest, drift: false}
    end

    test "a report without allow_first reads as an empty list", ctx do
      run = run_fixture(ctx.scope)

      events_fixture(run, [
        {1, "run.started", started_data()},
        {2, "run.policy_applied", %{"mode" => "observe", "allow" => [], "source" => "config"}}
      ])

      {:ok, run} = Projector.project(run)
      assert %{allow_first: [], allow_first_count: 0} = Record.policy(ctx.scope, run)
    end
  end
end
