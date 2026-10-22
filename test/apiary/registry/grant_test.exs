defmodule Apiary.Registry.GrantTest do
  # What a registry token grants (`Apiary.Registry.Grant`): only `pull` and `push`, only
  # on names of the layout, pull alone under `shared/` and `upstream/`, and never an entry
  # with an empty name or a name outside the layout.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Apiary.Registry.{Grant, Names}

  @target "0123456789abcdef/1111111111111111/targets/2222222222222222"
  @environment "0123456789abcdef/1111111111111111/environments/3333333333333333"
  @other "0123456789abcdef/1111111111111111/targets/4444444444444444"

  @build %{@target => ["pull", "push"], @environment => ["pull", "push"]}
  @reader %{@target => ["pull"]}

  defp entry(name, actions), do: %{type: "repository", name: name, actions: actions}

  test "grants the actions asked for that the run has, pull and push alone" do
    assert Grant.grant(@build, ["repository:#{@target}:pull,push,delete,*"]) ==
             {:ok, [entry(@target, ["pull", "push"])]}

    assert Grant.grant(@reader, ["repository:#{@target}:pull,push"]) ==
             {:ok, [entry(@target, ["pull"])]}

    assert Grant.grant(%{@target => ["pull", "push", "delete", "*"]}, [
             "repository:#{@target}:delete,*"
           ]) == {:ok, []}
  end

  test "leaves out a name outside the run, a scope of another type, and a bad scope" do
    assert Grant.grant(@build, [
             "repository:#{@other}:pull",
             "registry:catalog:*",
             "repository:#{@target}",
             "repository",
             "",
             "repository::pull"
           ]) == {:ok, []}
  end

  test "grants pull alone under shared/ and upstream/, whatever the rights" do
    rights = Map.merge(@build, %{"shared/base" => ["pull", "push"]})

    assert Grant.grant(rights, [
             "repository:shared/base:pull,push",
             "repository:upstream/docker.io/library/alpine:push,pull"
           ]) ==
             {:ok,
              [
                entry("shared/base", ["pull"]),
                entry("upstream/docker.io/library/alpine", ["pull"])
              ]}

    assert Grant.grant(rights, ["repository:shared/base:push"]) == {:ok, []}
  end

  test "keeps the order of each name's first scope, one entry a name" do
    assert Grant.grant(@build, [
             "repository:#{@environment}:push",
             "repository:#{@target}:pull",
             "repository:#{@environment}:pull"
           ]) ==
             {:ok, [entry(@environment, ["pull", "push"]), entry(@target, ["pull"])]}
  end

  test "reads the name up to the last colon, so a name with a port's colon is left out" do
    assert Grant.grant(@build, ["repository:registry.example:5000/#{@target}:pull"]) == {:ok, []}
  end

  test "refuses more than 16 scope parameters" do
    sixteen = List.duplicate("repository:#{@target}:pull", 16)
    assert {:ok, [_entry]} = Grant.grant(@build, sixteen)

    assert Grant.grant(@build, sixteen ++ ["registry:catalog:*"]) ==
             {:error, {:too_many_scopes, 17}}

    # One parameter of 17 scopes separated by spaces is one malformed scope.
    assert Grant.grant(@build, [Enum.join(sixteen ++ ["repository:#{@target}:pull"], " ")]) ==
             {:ok, []}
  end

  test "grants nothing of a scope parameter with whitespace in it" do
    for scope <- [
          "repository:#{@target}:pull repository:#{@environment}:pull",
          "repository:#{@target}:pull ",
          " repository:#{@target}:pull",
          "repository:#{@target}:pull,\tpush",
          "repository:#{@target}:pull\n"
        ] do
      assert Grant.grant(@build, [scope]) == {:ok, []}, inspect(scope)
    end
  end

  defp name_gen do
    one_of([
      constant(@target),
      constant(@environment),
      constant(""),
      constant("shared"),
      constant("shared/base"),
      constant("upstream/docker.io/library/alpine"),
      constant("upstream/registry.example/x"),
      string(:printable, max_length: 40),
      string([?a..?z, ?0..?9, ?/, ?., ?_, ?-, ?:], max_length: 60)
    ])
  end

  defp scope_gen do
    gen all(
          type <- member_of(["repository", "registry", "", "repository(plugin)"]),
          name <- name_gen(),
          actions <-
            list_of(member_of(["pull", "push", "delete", "*", ""]), min_length: 0, max_length: 4)
        ) do
      "#{type}:#{name}:#{Enum.join(actions, ",")}"
    end
  end

  property "never grants an entry with an empty name, a name outside the layout, or an action other than pull and push" do
    check all(
            rights <-
              member_of([%{}, @reader, @build, %{"" => ["pull", "push"], "x" => ["push"]}]),
            scopes <- list_of(scope_gen(), max_length: 16)
          ) do
      {:ok, entries} = Grant.grant(rights, scopes)

      for %{type: type, name: name, actions: actions} <- entries do
        assert type == "repository"
        assert name != ""
        assert Names.layout?(name)
        assert actions != [] and actions -- ["pull", "push"] == []
        assert actions == Enum.uniq(actions)

        if Names.shared?(name) or Names.upstream?(name),
          do: assert(actions == ["pull"]),
          else: assert(actions -- Map.get(rights, name, []) == [])
      end

      assert length(entries) == length(Enum.uniq_by(entries, & &1.name))
    end
  end
end
