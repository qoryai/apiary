defmodule Apiary.Policy.IntegrationResolutionTest do
  @moduledoc """
  The hosts an integration requires, as `Apiary.Policy.Resolution` takes them in: each
  an allow on every path that no rule takes out, the lowest allow among allows, and each
  in `allow_first`, outside `allow`. Every case that resolves is rendered, and the render
  validated against the contract's schema.
  """
  use ExUnit.Case, async: true

  alias Apiary.Policy.{Above, Entry, Render, Resolution, Rule, Schema}

  @tracker %{id: Ecto.UUID.generate(), public_id: "con_tracker", name: "acme-tracker"}
  @chat %{id: Ecto.UUID.generate(), public_id: "con_chat", name: "acme-chat"}

  defp allow(host, opts \\ []), do: host_rule("allow", host, opts)
  defp deny(host, opts \\ []), do: host_rule("deny", host, opts)

  defp host_rule(action, host, opts) do
    %Rule{kind: "host", action: action, host: host, paths: opts[:paths], locked: !!opts[:locked]}
  end

  defp hosts(connection, hosts), do: for(host <- hosts, do: %{host: host, connection: connection})

  defp resolve(workspace, target \\ [], integrations, above \\ nil) do
    target_id = if target != [], do: Ecto.UUID.generate()

    {:ok, effective} =
      Resolution.resolve("enforce", workspace, target, target_id, above, integrations)

    assert {:ok, document, allow_first} = Render.render(effective)
    assert :ok = Schema.validate(document)
    assert allow_first == effective.allow_first
    egress = Jason.decode!(document)["security_policy"]["egress"]

    if allow_first == [],
      do: refute(Map.has_key?(egress, "allow_first")),
      else: assert(egress["allow_first"] == allow_first)

    effective
  end

  defp entry(effective, source, host) do
    Enum.find(effective.entries, &(&1.source == source and &1.host == host))
  end

  test "an integration's host is allowed on every path, with its connection" do
    effective = resolve([allow("docs.example.com")], hosts(@tracker, ["api.example.com"]))

    assert effective.allow == ["docs.example.com"]
    assert effective.allow_first == ["api.example.com"]
    assert effective.paths == %{}

    assert %Entry{
             source: :integration,
             action: :allow,
             rule: nil,
             paths: nil,
             in_force: true,
             connection: @tracker
           } = entry(effective, :integration, "api.example.com")
  end

  test "beats a deny of the workspace, locked or not, and of a target" do
    integrations = hosts(@tracker, ["api.example.com"])

    for {workspace, target, source} <- [
          {[deny("api.example.com")], [], :workspace},
          {[deny("api.example.com", locked: true)], [], :workspace},
          {[], [deny("api.example.com")], :target},
          {[deny("api.example.com", locked: true)], [allow("api.example.com")], :workspace}
        ] do
      effective = resolve(workspace, target, integrations)

      assert effective.allow == []
      assert effective.allow_first == ["api.example.com"]
      assert effective.deny == []

      denied = Enum.find(effective.entries, &(&1.action == :deny and &1.source == source))
      refute denied.in_force
      assert %Entry{source: :integration, connection: @tracker} = denied.overridden_by
      assert entry(effective, :integration, "api.example.com").in_force
    end
  end

  test "beats a deny of the level above" do
    above = %Above{name: "Acme", rules: [deny("api.example.com")]}
    effective = resolve([], [], hosts(@tracker, ["api.example.com"]), above)

    assert effective.allow == []
    assert effective.allow_first == ["api.example.com"]
    assert effective.deny == []
    refute entry(effective, :organisation, "api.example.com").in_force
  end

  test "a *. deny that covers it stays in force, in deny, and denies a sibling host" do
    for mode <- ["observe", "enforce"] do
      {:ok, effective} =
        Resolution.resolve(
          mode,
          [deny("*.example.com"), allow("cdn.example.com")],
          [],
          nil,
          nil,
          hosts(@tracker, ["api.example.com"])
        )

      # cdn.example.com, a sibling, is denied by the deny in either mode.
      assert effective.allow == []
      assert effective.deny == ["*.example.com"]
      assert effective.allow_first == ["api.example.com"]
    end

    effective =
      resolve(
        [deny("*.example.com"), allow("cdn.example.com")],
        [],
        hosts(@tracker, ["api.example.com"])
      )

    wildcard = entry(effective, :workspace, "*.example.com")
    assert wildcard.in_force
    refute entry(effective, :workspace, "cdn.example.com").in_force

    integration = entry(effective, :integration, "api.example.com")
    assert integration.in_force
    assert [%Entry{host: "*.example.com", action: :deny}] = integration.overrides
  end

  test "a *. deny of the level above, locked or not, stays in deny" do
    above = %Above{name: "Acme", rules: [deny("*.example.com")]}

    for workspace <- [[], [deny("*.example.com", locked: true)]] do
      effective = resolve(workspace, [], hosts(@tracker, ["api.example.com"]), above)

      assert effective.deny == ["*.example.com"]
      assert effective.allow == []
      assert effective.allow_first == ["api.example.com"]
    end
  end

  test "a host that is not exact is left out, and adds nothing to allow_first" do
    effective =
      resolve(
        [deny("api.example.com")],
        [],
        hosts(@tracker, ["*.example.com", "api.example.com\n", "010.0.0.1"])
      )

    assert effective.allow == []
    assert effective.deny == ["api.example.com"]
    assert effective.allow_first == []
    refute Enum.any?(effective.entries, &(&1.source == :integration))
  end

  test "allow_first is the exact hosts, sorted, each once, and no host below them" do
    effective =
      resolve(
        [deny("*.example.com"), allow("a.api.example.com")],
        [deny("*.example.org")],
        hosts(@tracker, ["files.example.org", "api.example.com", "10.0.0.12"]) ++
          hosts(@chat, ["api.example.com", "chat.example.net"])
      )

    assert effective.allow_first ==
             ["10.0.0.12", "api.example.com", "chat.example.net", "files.example.org"]

    refute "a.api.example.com" in effective.allow_first
    refute "a.api.example.com" in effective.allow
    refute entry(effective, :workspace, "a.api.example.com").in_force
    assert effective.deny == ["*.example.com", "*.example.org"]
  end

  test "an allow of a rule on the host stays in force under a *. deny, and the deny in deny" do
    effective =
      resolve(
        [deny("*.example.com"), allow("api.example.com", paths: ["/v1/*"])],
        [],
        hosts(@tracker, ["api.example.com"])
      )

    assert effective.allow == ["api.example.com"]
    assert effective.paths == %{"api.example.com" => ["/v1/*"]}
    assert effective.deny == ["*.example.com"]
    assert effective.allow_first == ["api.example.com"]
    assert entry(effective, :workspace, "api.example.com").in_force
  end

  test "more than 64 hosts is no render" do
    many = for n <- 1..65, do: "host#{n}.example.com"
    {:ok, effective} = Resolution.resolve("enforce", [], [], nil, nil, hosts(@tracker, many))

    assert length(effective.allow_first) == 65
    assert Render.render(effective) == {:error, {:allow_first_too_long, 65}}

    {:ok, effective} =
      Resolution.resolve("enforce", [], [], nil, nil, hosts(@tracker, Enum.take(many, 64)))

    assert {:ok, _document, [_ | _] = allow_first} = Render.render(effective)
    assert length(allow_first) == 64
  end

  test "an allow of a rule on the same host decides it, and the host stays allowed" do
    effective =
      resolve(
        [allow("api.example.com", paths: ["/v1/*"])],
        [],
        hosts(@tracker, ["api.example.com"])
      )

    assert effective.allow == ["api.example.com"]
    assert effective.paths == %{"api.example.com" => ["/v1/*"]}

    integration = entry(effective, :integration, "api.example.com")
    refute integration.in_force
    assert %Entry{source: :workspace} = integration.overridden_by
  end

  test "two integrations that list one host stay in force together" do
    effective =
      resolve(
        [deny("api.example.com")],
        [],
        hosts(@tracker, ["api.example.com"]) ++ hosts(@chat, ["api.example.com"])
      )

    assert effective.allow == []
    assert effective.allow_first == ["api.example.com"]

    in_force =
      for %Entry{source: :integration, in_force: true, connection: c} <- effective.entries,
          do: c.public_id

    assert in_force == ["con_tracker", "con_chat"]
  end

  test "is not struck where the level above allows only the hosts on its list" do
    above = %Above{name: "Acme", own_allows: false, rules: [allow("models.example.com")]}

    effective =
      resolve([allow("docs.example.com")], [], hosts(@tracker, ["api.example.com"]), above)

    assert effective.allow == ["models.example.com"]
    assert effective.allow_first == ["api.example.com"]
    assert entry(effective, :integration, "api.example.com").in_force
    assert entry(effective, :workspace, "docs.example.com").reason == :only_above_allows
  end

  test "a *. allow held to paths leaves it on every path" do
    effective =
      resolve(
        [allow("*.example.com", paths: ["/docs/*"])],
        [],
        hosts(@tracker, ["api.example.com"])
      )

    assert effective.allow == ["*.example.com"]
    assert effective.allow_first == ["api.example.com"]
    assert effective.paths == %{"*.example.com" => ["/docs/*"], "api.example.com" => ["/*"]}

    above = %Above{name: "Acme", rules: [allow("*.example.com", paths: ["/docs/*"])]}
    effective = resolve([], [], hosts(@tracker, ["api.example.com"]), above)

    assert entry(effective, :integration, "api.example.com").in_force
    assert effective.paths["api.example.com"] == ["/*"]
  end

  test "no integration resolves as before" do
    rules = [deny("*.example.com", locked: true), allow("api.example.com")]

    assert {:ok, before} = Resolution.resolve("enforce", rules, [], nil, nil)
    assert Resolution.resolve("enforce", rules, [], nil, nil, []) == {:ok, before}
  end
end
