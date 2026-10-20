defmodule Apiary.Policy.IntegrationResolutionTest do
  @moduledoc """
  The hosts an integration requires, as `Apiary.Policy.Resolution` takes them in: each
  an allow on every path that no deny takes out, the lowest allow among allows. Every
  case that resolves is rendered, and the render validated against the contract's schema.
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

    assert :ok = Schema.validate(Render.document(effective))
    effective
  end

  defp entry(effective, source, host) do
    Enum.find(effective.entries, &(&1.source == source and &1.host == host))
  end

  test "an integration's host is allowed on every path, with its connection" do
    effective = resolve([allow("docs.example.com")], hosts(@tracker, ["api.example.com"]))

    assert effective.allow == ["api.example.com", "docs.example.com"]
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

      assert effective.allow == ["api.example.com"]
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

    assert effective.allow == ["api.example.com"]
    assert effective.deny == []
    refute entry(effective, :organisation, "api.example.com").in_force
  end

  test "a *. deny that covers it stays in force and is left out of deny" do
    effective =
      resolve(
        [deny("*.example.com"), allow("cdn.example.com")],
        [],
        hosts(@tracker, ["api.example.com"])
      )

    # cdn.example.com, a sibling, is not reached under enforce: it has no allow.
    assert effective.allow == ["api.example.com"]
    assert effective.deny == []

    wildcard = entry(effective, :workspace, "*.example.com")
    assert wildcard.in_force
    refute entry(effective, :workspace, "cdn.example.com").in_force

    integration = entry(effective, :integration, "api.example.com")
    assert integration.in_force
    assert [%Entry{host: "*.example.com", action: :deny}] = integration.overrides
  end

  test "a *. host of an integration beats a deny below it" do
    effective = resolve([deny("api.example.com")], [], hosts(@tracker, ["*.example.com"]))

    assert effective.allow == ["*.example.com"]
    assert effective.deny == []

    assert %Entry{source: :integration} =
             entry(effective, :workspace, "api.example.com").overridden_by
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

    assert effective.allow == ["api.example.com"]

    in_force =
      for %Entry{source: :integration, in_force: true, connection: c} <- effective.entries,
          do: c.public_id

    assert in_force == ["con_tracker", "con_chat"]
  end

  test "is not struck where the level above allows only the hosts on its list" do
    above = %Above{name: "Acme", own_allows: false, rules: [allow("models.example.com")]}

    effective =
      resolve([allow("docs.example.com")], [], hosts(@tracker, ["api.example.com"]), above)

    assert effective.allow == ["api.example.com", "models.example.com"]
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

    assert effective.allow == ["api.example.com", "*.example.com"]
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
